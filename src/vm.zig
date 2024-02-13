const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const compiler = @import("compiler.zig");
const objects = @import("object.zig");
const mem = @import("memory.zig");
const natives = @import("builtins/natives.zig");
const string_methods = @import("builtins/string_methods.zig");
const list_methods = @import("builtins/list_methods.zig");
const table_methods = @import("builtins/table_methods.zig");

const Value = values.Value;
const ValueTypeTag = values.ValueTypeTag;
const OpCode = chunks.OpCode;
const allocator = @import("memory.zig").allocator;

const stdout = std.io.getStdOut().writer();

const FRAMES_MAX = 2560;
const STACK_MAX = FRAMES_MAX * 256;

pub const CallFrame = struct {
    closure: *objects.ObjClosure,
    ip: [*]u8,
    slots: [*]Value,
};

pub const InterpretResult = enum {
    ok,
    compiler_error,
    runtime_error,
};

pub const VM = struct {
    frames: [FRAMES_MAX]CallFrame = undefined,
    frame_count: u16 = undefined,
    stack: [STACK_MAX]values.Value = undefined,
    stack_top: [*]values.Value = undefined,
    strings: std.hash_map.StringHashMap(*objects.ObjString) = undefined,
    init_string: ?*objects.ObjString = null,
    globals: std.hash_map.AutoHashMap(*objects.ObjString, values.Value) = undefined,

    string_methods: std.hash_map.AutoHashMap(*objects.ObjString, values.Value) = undefined,
    list_methods: std.hash_map.AutoHashMap(*objects.ObjString, values.Value) = undefined,
    table_methods: std.hash_map.AutoHashMap(*objects.ObjString, values.Value) = undefined,

    bytes_allocated: u64 = 0,
    next_gc: u64 = 8 * 1024,
    objects: ?*objects.Obj = null,
    open_upvalues: ?*objects.ObjUpvalue = null,

    gray_stack: *std.ArrayList(*objects.Obj) = undefined,
    gray_count: usize = 0,
    gray_capacity: usize = 0,

    pub fn init(self: *VM) !void {
        mem.initVM(self);
        objects.initVM(self);
        chunks.initVM(self);
        self.objects = null;
        self.gray_stack = try allocator.create(std.ArrayList(*objects.Obj));
        self.gray_stack.* = std.ArrayList(*objects.Obj).init(allocator);

        self.strings = std.hash_map.StringHashMap(*objects.ObjString).init(allocator);
        self.globals = std.hash_map.AutoHashMap(*objects.ObjString, values.Value).init(allocator);

        self.string_methods = std.hash_map.AutoHashMap(*objects.ObjString, values.Value).init(allocator);
        self.list_methods = std.hash_map.AutoHashMap(*objects.ObjString, values.Value).init(allocator);
        self.table_methods = std.hash_map.AutoHashMap(*objects.ObjString, values.Value).init(allocator);

        self.resetStack();
        self.init_string = null;
        self.init_string = try objects.ObjString.copy("init", 4);

        natives.init(self);
        string_methods.init(self);
        list_methods.init(self);
        table_methods.init(self);
    }

    pub fn freeVM(self: *const VM) void {
        @constCast(self).strings.deinit();
        @constCast(self).globals.deinit();
        @constCast(self).string_methods.deinit();
        @constCast(self).list_methods.deinit();
        @constCast(self).table_methods.deinit();
        @constCast(self).init_string = null;
        mem.freeObjects();
    }

    fn resetStack(self: *VM) void {
        self.stack_top = &self.stack;
        self.frame_count = 0;
    }

    pub fn runtimeError(self: *VM, comptime format: [*:0]const u8, args: anytype) void {
        const stderr = std.io.getStdErr().writer();
        stderr.print("ERROR: " ++ format ++ " @ ", args) catch {};

        var i: usize = self.frame_count;
        while (i > 0) {
            i -= 1;
            const frame: *CallFrame = &self.frames[i];
            const function = frame.closure.function;
            const instruction: usize = @intFromPtr(frame.ip) - @intFromPtr(frame.closure.function.chunk.code.items.ptr) - 1;
            stderr.print("[line {d}] in ", .{frame.closure.function.chunk.lines.items[instruction]}) catch {};
            if (function.name == null) {
                stderr.print("script\n", .{}) catch {};
            } else {
                stderr.print("{s}()\n", .{function.name.?.chars}) catch {};
            }
        }
        self.resetStack();
    }

    pub fn push(self: *VM, value: values.Value) void {
        self.stack_top[0] = value;
        self.stack_top += @as(usize, 1);
    }

    pub fn pop(self: *VM) values.Value {
        self.stack_top -= @as(usize, 1);
        return self.stack_top[0];
    }

    fn peek(self: *VM, distance: usize) values.Value {
        const item_ptr = self.stack_top - (1 + distance);
        return item_ptr[0];
    }

    fn call(self: *VM, closure: *objects.ObjClosure, arg_count: u8) bool {
        if (arg_count != closure.function.arity) {
            self.runtimeError("Expected {d} arguments but got {d}.", .{ closure.function.arity, arg_count });
            return false;
        }

        if (self.frame_count == FRAMES_MAX) {
            self.runtimeError("Stack overflow.", .{});
            return false;
        }

        const frame: *CallFrame = &self.frames[self.frame_count];
        self.frame_count += 1;
        frame.closure = closure;
        frame.ip = closure.function.chunk.code.items.ptr;
        frame.slots = self.stack_top - arg_count - 1;
        return true;
    }

    fn callNativeMethod(self: *VM, callee: Value, arg_count: u8, object: *objects.Obj) !bool {
        const method = callee.asNativeMethod();
        const result = try method.function(object, arg_count, self.stack_top - arg_count);
        self.stack_top -= arg_count + 1;
        self.push(result);
        return true;
    }

    fn callValue(self: *VM, callee: Value, arg_count: u8) !bool {
        if (callee.isObj()) {
            switch (callee.as.obj.type) {
                objects.ObjType.BoundMethod => {
                    const bound = callee.asBoundMethod();
                    const slot = self.stack_top - @as(usize, @intCast(arg_count)) - 1;
                    slot[0] = bound.reciever;
                    return self.call(bound.method, arg_count);
                },
                objects.ObjType.BoundNativeMethod => {
                    const bound = callee.asBoundNativeMethod();
                    // const slot = self.stack_top - @as(usize, @intCast(arg_count)) - 1;
                    // slot[0] = bound.reciever;
                    return self.callNativeMethod(Value.makeObj(@ptrCast(bound.method)), arg_count, bound.reciever.as.obj);
                },
                objects.ObjType.Closure => {
                    return self.call(callee.asClosure(), arg_count);
                },
                objects.ObjType.Native => {
                    const native = callee.asNative();

                    const result = try native.function(arg_count, self.stack_top - arg_count);
                    if (result.isError()) {
                        return false;
                    }
                    self.stack_top -= arg_count + 1;
                    self.push(result);
                    return true;
                },
                objects.ObjType.Class => {
                    const class: *objects.ObjClass = callee.asClass();
                    const slot = self.stack_top - @as(usize, @intCast(arg_count)) - 1;
                    const instance = try objects.ObjInstance.init(class);
                    slot[0] = Value.makeObj(@ptrCast(instance));
                    const initializer = class.methods.get(self.init_string.?);
                    if (initializer) |i| {
                        return self.call(i.asClosure(), arg_count);
                    } else if (arg_count != 0) {
                        self.runtimeError("Expected 0 arguments but got {d}.", .{arg_count});
                        return false;
                    }
                    return true;
                },
                else => {},
            }
        }
        self.runtimeError("Can only call functions and classes", .{});
        return false;
    }

    fn invoke(self: *VM, name: *objects.ObjString, arg_count: u8) !bool {
        const receiver = self.peek(arg_count);

        if (receiver.isInstance()) {
            const instance = receiver.asInstance();

            const value_result = instance.fields.get(name);
            if (value_result) |value| {
                const slot = self.stack_top - @as(usize, @intCast(arg_count)) - 1;
                slot[0] = value;
                if (value.isNativeMethod()) {
                    return self.callNativeMethod(value, arg_count, @ptrCast(instance));
                }
                return try self.callValue(value, arg_count);
            }
            return self.invokeFromClass(instance, instance.class, name, arg_count);
        } else if (receiver.isList()) {
            const list = receiver.as.obj;
            const method_result = self.list_methods.get(name);
            if (method_result) |method| {
                return try self.callNativeMethod(method, arg_count, list);
            }
            self.runtimeError("Invalid list method.", .{});
            return false;
        } else if (receiver.isString()) {
            const string = receiver.as.obj;
            const method_result = self.string_methods.get(name);
            if (method_result) |method| {
                return try self.callNativeMethod(method, arg_count, string);
            }
            self.runtimeError("Invalid list method.", .{});
            return false;
        } else if (receiver.isTable()) {
            const table = receiver.as.obj;
            const method_result = self.table_methods.get(name);
            if (method_result) |method| {
                return try self.callNativeMethod(method, arg_count, table);
            }
            self.runtimeError("Invalid table method.", .{});
            return false;
        }
        self.runtimeError("Only instances have methods.", .{});
        return false;
    }

    fn invokeFromClass(self: *VM, instance: ?*objects.ObjInstance, class: *objects.ObjClass, name: *objects.ObjString, arg_count: u8) bool {
        const method_result = class.methods.get(name);
        if (method_result) |method| {
            // std.debug.print("{any}", .{method.as.obj.type});
            if (method.isClosure()) {
                return self.call(method.asClosure(), arg_count);
            } else if (method.isNativeMethod()) {
                return self.callNativeMethod(method, arg_count, @ptrCast(instance.?)) catch {
                    return false;
                };
            }
        }
        self.runtimeError("Undefined property '{s}'.", .{name.chars});
        return false;
    }

    fn bindMethod(self: *VM, class: *objects.ObjClass, name: *objects.ObjString) !bool {
        const method_result = class.methods.get(name);

        if (method_result) |method| {
            // if (method.isClosure()) {
            const bound = try objects.ObjBoundMethod.init(self.peek(0), method.asClosure());
            _ = self.pop();
            self.push(Value.makeObj(@ptrCast(bound)));
            // } else if (method.isNativeMethod()) {
            //     const bound = try objects.ObjBoundNativeMethod.init(self.peek(0), method.asNativeMethod());
            //     // std.debug.print("binding native method\n", .{});
            //     _ = self.pop();
            //     self.push(Value.makeObj(@ptrCast(bound)));
            // }
            return true;
        }

        self.runtimeError("Undefined property '{s}'.", .{name.chars});
        return false;
    }

    fn bindNativeMethod(self: *VM, object: *objects.Obj, name: *objects.ObjString) !bool {
        var bound: *objects.ObjBoundNativeMethod = undefined;
        var method_result: ?Value = null;

        switch (object.type) {
            objects.ObjType.Instance => {
                const instance: *objects.ObjInstance = @ptrCast(object);
                method_result = instance.fields.get(name);
            },
            objects.ObjType.List => method_result = self.list_methods.get(name),
            objects.ObjType.Table => method_result = self.table_methods.get(name),
            objects.ObjType.String => method_result = self.string_methods.get(name),
            else => {},
        }

        if (method_result) |method| {
            bound = try objects.ObjBoundNativeMethod.init(self.peek(0), method.asNativeMethod());
            _ = self.pop();
            self.push(Value.makeObj(@ptrCast(bound)));
            return true;
        }

        self.runtimeError("Undefined property '{s}'.", .{name.chars});
        return false;
    }

    fn captureUpvalue(self: *VM, local: [*]Value) !*objects.ObjUpvalue {
        var prev: ?*objects.ObjUpvalue = null;
        var upvalue = self.open_upvalues;
        while (upvalue != null and @intFromPtr(upvalue.?.location) > @intFromPtr(&local[0])) {
            prev = upvalue;
            upvalue = upvalue.?.next;
        }

        if (upvalue != null and @intFromPtr(upvalue.?.location) == @intFromPtr(&local[0])) {
            return upvalue.?;
        }

        const createdUpvalue = try objects.ObjUpvalue.init(&local[0]);
        createdUpvalue.next = upvalue;
        if (prev == null) {
            self.open_upvalues = createdUpvalue;
        } else {
            prev.?.next = createdUpvalue;
        }
        return createdUpvalue;
    }

    fn closeUpvalue(self: *VM, last: [*]Value) void {
        while (self.open_upvalues != null and @intFromPtr(self.open_upvalues.?.location) >= @intFromPtr(last)) {
            const upvalue = self.open_upvalues.?;
            upvalue.closed = upvalue.location.*;
            upvalue.location = &upvalue.closed;
            self.open_upvalues = upvalue.next;
        }
    }

    fn defineField(self: *VM, name: *objects.ObjString) void {
        const value = self.peek(0);
        const class = self.peek(1).asClass();
        class.addField(name, value);
        _ = self.pop();
    }

    fn defineMethod(self: *VM, name: *objects.ObjString) void {
        const method = self.peek(0);
        const class = self.peek(1).asClass();
        class.addMethod(name, method);
        _ = self.pop();
    }

    fn isFalsey(self: *VM, value: values.Value) bool {
        _ = self;
        return value.isNull() or (value.isBool() and !value.as.bool);
    }

    fn concatenate(self: *VM) !void {
        const b = values.valueToString(self.peek(0));
        const a: *objects.ObjString = self.peek(1).asString();
        const length = a.chars.len + b.len;
        var chars = try allocator.alloc(u8, length + 1);
        // const string = a.chars ++ b.chars;
        const string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ a.chars, b });
        std.mem.copyForwards(u8, chars, string);
        chars[length] = 0;

        const result = try objects.ObjString.take(chars, length);
        const res_obj: *objects.Obj = @ptrCast(result);
        _ = self.pop();
        _ = self.pop();
        self.push(Value.makeObj(res_obj));
    }

    pub fn interpret(self: *VM, source: []const u8) !InterpretResult {
        const function_result = compiler.compile(source);

        if (function_result) |function| {
            self.push(values.Value.makeObj(@ptrCast(function)));
            const closure = objects.ObjClosure.init(function) catch {
                return InterpretResult.compiler_error;
            };
            _ = self.pop();
            self.push(Value.makeObj(@ptrCast(closure)));
            _ = self.call(closure, 0);
        } else {
            return InterpretResult.compiler_error;
        }

        return try self.run();
    }

    fn readByte(self: *VM, frame: *CallFrame) u8 {
        _ = self;
        const result = frame.ip;
        frame.ip += 1;
        return result[0];
    }

    fn readShort(self: *VM, frame: *CallFrame) u16 {
        const b1: u16 = self.readByte(frame);
        const b2: u16 = self.readByte(frame);
        const result: u16 = (b1 * 256) + b2;
        return result;
    }

    fn readConstant(self: *VM, frame: *CallFrame) values.Value {
        return frame.closure.function.chunk.constants.values.items[self.readByte(frame)];
    }

    fn readConstant_16(self: *VM, frame: *CallFrame) values.Value {
        return frame.closure.function.chunk.constants.values.items[self.readShort(frame)];
    }

    fn run(self: *VM) !InterpretResult {
        var frame: *CallFrame = &self.frames[self.frame_count - 1];

        while (true) {
            if (debug.debug_trace_stack) {
                std.debug.print("          ", .{});
                var slot: [*]values.Value = &self.stack;
                const shift: usize = 1;
                while (@intFromPtr(slot) < @intFromPtr(self.stack_top)) : (slot += shift) {
                    std.debug.print("[ ", .{});
                    values.printValue(slot[0]);
                    std.debug.print(" ]", .{});
                }
                std.debug.print("\n", .{});
                const offset = frame.ip - @as(usize, @intFromPtr(frame.closure.function.chunk.code.items.ptr));
                _ = debug.disassembleInstruction(&frame.closure.function.chunk, @intFromPtr(offset));
            }
            const instruction: OpCode = @enumFromInt(self.readByte(frame));
            switch (instruction) {
                OpCode.Constant => {
                    const constant = self.readConstant(frame);
                    self.push(constant);
                },
                OpCode.Constant_16 => {
                    const constant = self.readConstant_16(frame);
                    self.push(constant);
                },
                OpCode.Null => self.push(Value.makeNull()),
                OpCode.True => self.push(Value.makeBool(true)),
                OpCode.False => self.push(Value.makeBool(false)),
                OpCode.Pop => {
                    _ = self.pop();
                },
                OpCode.GetLocal => {
                    const slot: usize = self.readByte(frame);
                    self.push(frame.slots[slot]);
                },
                OpCode.GetLocal_16 => {
                    const slot = self.readShort(frame);
                    self.push(frame.slots[slot]);
                },
                OpCode.SetLocal => {
                    const slot: usize = self.readByte(frame);
                    frame.slots[slot] = self.peek(0);
                },
                OpCode.SetLocal_16 => {
                    const slot = self.readShort(frame);
                    frame.slots[slot] = self.peek(0);
                },
                OpCode.GetGlobal => {
                    const name = self.readConstant(frame).asString();
                    const value = self.globals.get(name);
                    if (value == null) {
                        self.runtimeError("Undefined variable '{s}'.", .{name.chars});
                        return InterpretResult.runtime_error;
                    }
                    self.push(value.?);
                },
                OpCode.GetGlobal_16 => {
                    const name = self.readConstant_16(frame).asString();
                    const value = self.globals.get(name);
                    if (value != null) {
                        self.push(value.?);
                    } else {
                        self.runtimeError("Undefined variable '{s}'.", .{name.chars});
                        return InterpretResult.runtime_error;
                    }
                },
                OpCode.DefineGlobal => {
                    const name: *objects.ObjString = self.readConstant(frame).asString();
                    self.globals.put(name, self.peek(0)) catch {};
                    _ = self.pop();
                },
                OpCode.DefineGlobal_16 => {
                    const name = self.readConstant_16(frame).asString();
                    self.globals.put(name, self.peek(0)) catch {};
                    _ = self.pop();
                },
                OpCode.SetGlobal => {
                    const name = self.readConstant(frame).asString();
                    const value = self.globals.get(name);
                    if (value == null) {
                        self.runtimeError("Undefined variable '{s}'.", .{name.chars});
                        return InterpretResult.runtime_error;
                    } else {
                        self.globals.put(name, self.peek(0)) catch {};
                    }
                },
                OpCode.SetGlobal_16 => {
                    const name = self.readConstant_16(frame).asString();
                    const value = self.globals.get(name);
                    if (value == null) {
                        self.runtimeError("Undefined variable '{s}'.", .{name.chars});
                        return InterpretResult.runtime_error;
                    } else {
                        self.globals.put(name, self.peek(0)) catch {};
                    }
                },
                OpCode.GetUpvalue => {
                    const slot = self.readByte(frame);
                    self.push(frame.closure.upvalues[slot].?.location.*);
                },
                OpCode.SetUpvalue => {
                    const slot = self.readByte(frame);
                    frame.closure.upvalues[slot].?.location.* = self.peek(0);
                },
                OpCode.GetProperty => {
                    const name = self.readConstant_16(frame).asString();
                    if (self.peek(0).isString() or self.peek(0).isList() or self.peek(0).isTable()) {
                        if (!(try self.bindNativeMethod(self.peek(0).as.obj, name))) {
                            return InterpretResult.runtime_error;
                        }
                    } else if (self.peek(0).isInstance()) {
                        const instance = self.peek(0).asInstance();
                        const value_result = instance.fields.get(name);
                        if (value_result) |value| {
                            if (value.isNativeMethod()) {
                                if (!(try self.bindNativeMethod(self.peek(0).as.obj, name))) {
                                    return InterpretResult.runtime_error;
                                }
                            } else {
                                _ = self.pop();
                                self.push(value);
                            }
                        } else {
                            if (!(try self.bindMethod(instance.class, name))) {
                                return InterpretResult.runtime_error;
                            }
                            // runtimeError("Undefined property '{s}'.", .{name.chars});
                            // return InterpretResult.runtime_error;
                        }
                    } else {
                        self.runtimeError("Only instances have properties.", .{});
                        return InterpretResult.runtime_error;
                    }
                },
                OpCode.SetProperty => {
                    if (!self.peek(1).isInstance()) {
                        self.runtimeError("Only instances have fields.", .{});
                        return InterpretResult.runtime_error;
                    }
                    const instance = self.peek(1).asInstance();
                    instance.setProperty(self.readConstant_16(frame).asString(), self.peek(0));
                    const value = self.pop();
                    _ = self.pop();
                    self.push(value);
                },
                OpCode.GetSuper => {
                    const name = self.readConstant_16(frame).asString();
                    const superclass = self.pop().asClass();
                    if (!(self.bindMethod(superclass, name) catch true)) {
                        return InterpretResult.runtime_error;
                    }
                },
                OpCode.Equal => {
                    const value_a = self.pop();
                    const value_b = self.pop();
                    self.push(Value.makeBool(values.valuesEqual(value_a, value_b)));
                },
                OpCode.Greater => {
                    if (!self.peek(0).isNumber() and !self.peek(1).isNumber()) {
                        self.runtimeError("Operands must be numbers", .{});
                        return InterpretResult.runtime_error;
                    }
                    const value_a = self.pop().as.number;
                    const value_b = self.pop().as.number;
                    const new_value = Value.makeBool(value_a < value_b);
                    self.push(new_value);
                },
                OpCode.Less => {
                    if (!self.peek(0).isNumber() and !self.peek(1).isNumber()) {
                        self.runtimeError("Operands must be numbers", .{});
                        return InterpretResult.runtime_error;
                    }
                    const value_a = self.pop().as.number;
                    const value_b = self.pop().as.number;
                    const new_value = Value.makeBool(value_a > value_b);
                    self.push(new_value);
                },
                OpCode.Add => {
                    if (
                    //     objects.isObjType(
                    //     peek(0),
                    //     objects.ObjType.String,
                    // ) and
                    objects.isObjType(
                        self.peek(1),
                        objects.ObjType.String,
                    )) {
                        self.concatenate() catch {};
                    } else if (self.peek(0).isNumber() and self.peek(1).isNumber()) {
                        const value_a = self.pop().as.number;
                        const value_b = self.pop().as.number;
                        const new_value = Value.makeNumber(value_a + value_b);
                        self.push(new_value);
                    } else {
                        self.runtimeError("Operands must be numbers or a string concatenation", .{});
                        return InterpretResult.runtime_error;
                    }
                },
                OpCode.Subtract => {
                    if (!self.peek(0).isNumber() or !self.peek(1).isNumber()) {
                        self.runtimeError("Operands must be numbers", .{});
                        return InterpretResult.runtime_error;
                    }
                    const value_a = self.pop().as.number;
                    const value_b = self.pop().as.number;
                    const new_value = Value.makeNumber(value_b - value_a);
                    self.push(new_value);
                },
                OpCode.Multiply => {
                    if (!self.peek(0).isNumber() or !self.peek(1).isNumber()) {
                        self.runtimeError("Operands must be numbers", .{});
                        return InterpretResult.runtime_error;
                    }
                    const value_a = self.pop().as.number;
                    const value_b = self.pop().as.number;
                    const new_value = Value.makeNumber(value_b * value_a);
                    self.push(new_value);
                },
                OpCode.Divide => {
                    if (!self.peek(0).isNumber() or !self.peek(1).isNumber()) {
                        self.runtimeError("Operands must be numbers", .{});
                        return InterpretResult.runtime_error;
                    }
                    const value_a = self.pop().as.number;
                    if (value_a == 0) {
                        self.runtimeError("Denominator cannot be 0.", .{});
                        return InterpretResult.runtime_error;
                    }
                    const value_b = self.pop().as.number;
                    const new_value = Value.makeNumber(value_b / value_a);
                    self.push(new_value);
                },
                OpCode.Modulo => {
                    if (!self.peek(0).isNumber() or !self.peek(1).isNumber()) {
                        self.runtimeError("Operands must be numbers.", .{});
                        return InterpretResult.runtime_error;
                    }
                    const value_a = self.pop().as.number;
                    if (value_a == 0) {
                        self.runtimeError("Denominator cannot be 0.", .{});
                        return InterpretResult.runtime_error;
                    }
                    const value_b = self.pop().as.number;
                    const new_value = Value.makeNumber(@mod(value_b, value_a));
                    self.push(new_value);
                },
                OpCode.Not => {
                    self.push(Value.makeBool(self.isFalsey(self.pop())));
                },
                OpCode.Negate => {
                    const value = self.peek(0);
                    if (!value.isNumber()) {
                        self.runtimeError("Operand must be a number.", .{});
                        return InterpretResult.runtime_error;
                    }
                    const new_value = Value.makeNumber(0 - value.as.number);
                    self.push(new_value);
                },
                OpCode.Print => {
                    values.printValue(self.pop());
                    stdout.print("\n", .{}) catch {};
                },
                OpCode.Jump => {
                    const offset = self.readShort(frame);
                    frame.ip += offset;
                },
                OpCode.JumpIfFalse => {
                    const offset = self.readShort(frame);
                    if (self.isFalsey(self.peek(0))) frame.ip += offset;
                },
                OpCode.Loop => {
                    const offset = self.readShort(frame);
                    frame.ip -= offset;
                },
                OpCode.Call => {
                    const arg_count = self.readByte(frame);
                    if (!(try self.callValue(self.peek(arg_count), arg_count))) {
                        return InterpretResult.runtime_error;
                    }
                    frame = &self.frames[self.frame_count - 1];
                },
                OpCode.Invoke => {
                    const method = self.readConstant_16(frame).asString();
                    const arg_count = self.readByte(frame);
                    if (!(try self.invoke(method, arg_count))) {
                        return InterpretResult.runtime_error;
                    }
                    frame = &self.frames[self.frame_count - 1];
                },
                OpCode.SuperInvoke => {
                    const method = self.readConstant_16(frame).asString();
                    const arg_count = self.readByte(frame);
                    const superclass = self.pop().asClass();
                    if (!self.invokeFromClass(null, superclass, method, arg_count)) {
                        return InterpretResult.runtime_error;
                    }
                    frame = &self.frames[self.frame_count - 1];
                },
                OpCode.Closure => {
                    const function: *objects.ObjFunction = self.readConstant(frame).asFunction();
                    const closure: *objects.ObjClosure = try objects.ObjClosure.init(function);
                    self.push(Value.makeObj(@ptrCast(closure)));
                    var i: usize = 0;
                    while (i < closure.upvalue_count) : (i += 1) {
                        const is_local = self.readByte(frame);
                        const index = self.readByte(frame);
                        if (is_local == 1) {
                            // const local = frame.slots + index;
                            // _ = local; // autofix
                            closure.upvalues[i] = try self.captureUpvalue(frame.slots + index);
                        } else {
                            closure.upvalues[i] = frame.closure.upvalues[index];
                        }
                    }
                },
                OpCode.Closure_16 => {
                    const function: *objects.ObjFunction = self.readConstant_16(frame).asFunction();
                    const closure: *objects.ObjClosure = try objects.ObjClosure.init(function);
                    self.push(Value.makeObj(@ptrCast(closure)));
                },
                OpCode.CloseUpvalue => {
                    self.closeUpvalue((self.stack_top - 1));
                    _ = self.pop();
                },
                OpCode.Return => {
                    const result = self.pop();
                    self.closeUpvalue(frame.slots);
                    self.frame_count -= 1;
                    if (self.frame_count == 0) {
                        _ = self.pop();
                        return InterpretResult.ok;
                    }

                    self.stack_top = frame.slots;
                    self.push(result);
                    frame = &self.frames[self.frame_count - 1];
                },
                OpCode.Class => {
                    const class = try objects.ObjClass.init(self.readConstant_16(frame).asString());
                    self.push(Value.makeObj(@ptrCast(class)));
                },
                OpCode.Inherit => {
                    const superclass = self.peek(1);
                    if (!superclass.isClass()) {
                        self.runtimeError("Superclass must be a class.", .{});
                        return InterpretResult.runtime_error;
                    }
                    const subclass = self.peek(0).asClass();
                    subclass.methods.* = try superclass.asClass().methods.clone();
                    subclass.fields.* = try superclass.asClass().fields.clone();
                    _ = self.pop();
                },
                OpCode.Field => self.defineField(self.readConstant_16(frame).asString()),
                OpCode.Method => self.defineMethod(self.readConstant_16(frame).asString()),
                OpCode.BuildList => {
                    const list = try objects.ObjList.init();
                    var item_count = self.readByte(frame);

                    self.push(Value.makeObj(@ptrCast(list)));
                    var i = item_count;
                    while (i > 0) : (i -= 1) {
                        list.append(self.peek(i));
                    }

                    _ = self.pop();

                    while (item_count > 0) : (item_count -= 1) {
                        _ = self.pop();
                    }

                    self.push(Value.makeObj(@ptrCast(list)));
                },
                OpCode.IndexSubscr => {
                    if (!self.peek(1).isList() and !self.peek(1).isString()) {
                        self.runtimeError("Invalid type to index into.", .{});
                        return InterpretResult.runtime_error;
                    }

                    if (!self.peek(0).isNumber()) {
                        self.runtimeError("Index is not a number.", .{});
                        return InterpretResult.runtime_error;
                    }
                    var result: Value = undefined;
                    const index: usize = @intFromFloat(self.pop().as.number);
                    if (self.peek(0).isList()) {
                        const list = self.pop().asList();

                        if (!list.isValidIndex(@intCast(index))) {
                            self.runtimeError("List index out of range.", .{});
                            return InterpretResult.runtime_error;
                        }

                        result = list.getByIndex(index);
                    } else if (self.peek(0).isString()) {
                        const string = self.pop().asString();
                        if (index < 0 or index >= string.chars.len) {
                            self.runtimeError("Index out of range.", .{});
                            return InterpretResult.runtime_error;
                        }
                        result = Value.makeObj(@ptrCast(try objects.ObjString.take(string.chars[index .. index + 1], 1)));
                    }
                    self.push(result);
                },
                OpCode.StoreSubscr => {
                    if (!self.peek(2).isList()) {
                        self.runtimeError("Cannot store value to non-list.", .{});
                        return InterpretResult.runtime_error;
                    }
                    if (!self.peek(1).isNumber()) {
                        self.runtimeError("List index not a number.", .{});
                        return InterpretResult.runtime_error;
                    }
                    const item = self.pop();
                    const index: usize = @intFromFloat(self.pop().as.number);
                    const list = self.pop().asList();

                    if (!list.isValidIndex(index)) {
                        self.runtimeError("List index out of range.", .{});
                        return InterpretResult.runtime_error;
                    }

                    list.store(index, item);
                    self.push(item);
                },
            }
        }
        return InterpretResult.runtime_error;
    }
};
