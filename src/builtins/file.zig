const std = @import("std");
const obj = @import("../object.zig");
const value = @import("../value.zig");
const Value = @import("../value.zig").Value;
const VM = @import("../vm.zig");
const mem = @import("../memory.zig");
const natives = @import("natives.zig");

pub fn fileNative(arg_count: u8, args: [*]Value) Value {
    if (arg_count != 1) {
        return Value.makeError("Expected 1 arguments but got {d}.", .{arg_count});
    }
    if (!args[0].isString()) {
        return Value.makeError("File path must be a string.", .{});
    }
    const class_name = obj.ObjString.copy("File", 4);
    const class = obj.ObjClass.init(class_name);
    const instance = obj.ObjInstance.init(class);
    const write_file_name = obj.ObjString.copy("write", 5);
    const write_class_method = obj.ObjNativeMethod.init(writeFileNativeMethod, obj.ObjType.Instance);
    const read_file_name = obj.ObjString.copy("read", 4);
    const read_class_method = obj.ObjNativeMethod.init(readFileNativeMethod, obj.ObjType.Instance);
    const append_file_name = obj.ObjString.copy("append", 6);
    const append_class_method = obj.ObjNativeMethod.init(appendFileNativeMethod, obj.ObjType.Instance);
    const get_lines_name = obj.ObjString.copy("getLines", 8);
    const get_lines_method = obj.ObjNativeMethod.init(getLines, obj.ObjType.Instance);
    instance.setProperty(write_file_name, Value.makeObj(@ptrCast(write_class_method)));
    instance.setProperty(read_file_name, Value.makeObj(@ptrCast(read_class_method)));
    instance.setProperty(append_file_name, Value.makeObj(@ptrCast(append_class_method)));
    instance.setProperty(get_lines_name, Value.makeObj(@ptrCast(get_lines_method)));
    const path_field = obj.ObjString.copy("path", 4);
    instance.setProperty(path_field, Value.makeObj(@ptrCast(args[0].asString())));
    return Value.makeObj(@ptrCast(instance));
}

pub fn readFileNativeMethod(object: *obj.Obj, arg_count: u8, args: [*]Value) Value {
    if (arg_count != 0) {
        return Value.makeError("Expected 0 arguments but got {d}.", .{arg_count});
    }

    const instance: *obj.ObjInstance = @ptrCast(object);

    const path: []const u8 = instance.fields.get(obj.ObjString.copy("path", 4)).?.asString().chars;
    var file: std.fs.File = undefined;

    file = std.fs.cwd().openFile(path[0 .. path.len - 1], .{}) catch {
        _ = std.fs.cwd().createFile(path[0 .. path.len - 1], .{}) catch {
            return Value.makeError("Unable to open file '{s}'.", .{args[0].asString().chars});
        };
        const string = obj.ObjString.allocate("", 0);
        return Value.makeObj(@ptrCast(string));
    };
    defer file.close();
    const file_contents = file.readToEndAlloc(mem.allocator, 100_000_000) catch {
        return Value.makeError("Unable to read file '{s}'.", .{args[0].asString().chars});
    };
    const res_string = obj.ObjString.allocate(file_contents, file_contents.len);
    return Value.makeObj(@ptrCast(res_string));
}

pub fn writeFileNativeMethod(object: *obj.Obj, arg_count: u8, args: [*]Value) Value {
    if (arg_count != 1) {
        return Value.makeError("Expected 1 arguments but got {d}.", .{arg_count});
    }
    const instance: *obj.ObjInstance = @ptrCast(object);

    const path: []const u8 = instance.fields.get(obj.ObjString.copy("path", 4)).?.asString().chars;

    var file = std.fs.cwd().createFile(path[0 .. path.len - 1], .{}) catch {
        return Value.makeError("Unable to write to file", .{});
    };
    const string = value.valueToString(args[0]);
    _ = file.write(string[0 .. string.len - 1]) catch {
        return Value.makeError("Unable to write to file '{s}'.", .{args[0].asString().chars});
    };
    defer file.close();
    return Value.makeNull();
}

pub fn appendFileNativeMethod(object: *obj.Obj, arg_count: u8, args: [*]Value) Value {
    if (arg_count != 1) {
        return Value.makeError("Expected 1 arguments but got {d}.", .{arg_count});
    }
    const instance: *obj.ObjInstance = @ptrCast(object);

    const path: []const u8 = instance.fields.get(obj.ObjString.copy("path", 4)).?.asString().chars;

    var file = std.fs.cwd().openFile(path[0 .. path.len - 1], .{ .mode = .read_write }) catch {
        return Value.makeError("Unable to open file.", .{});
    };

    const contents = file.readToEndAlloc(mem.allocator, 100000000) catch {
        return Value.makeError("Unable to read file.", .{});
    };
    _ = file.seekTo(contents.len) catch {
        return Value.makeError("Unable to read file.", .{});
    };
    const string = value.valueToString(args[0]);
    _ = file.write(string[0 .. string.len - 1]) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        return Value.makeError("Unable to write to file.", .{});
    };
    defer file.close();
    return Value.makeNull();
}

pub fn getLines(object: *obj.Obj, arg_count: u8, args: [*]Value) Value {
    _ = args;
    if (arg_count != 0) {
        return Value.makeError("Expected 0 arguments but got {d}.", .{arg_count});
    }
    const instance: *obj.ObjInstance = @ptrCast(object);

    const path: []const u8 = instance.fields.get(obj.ObjString.copy("path", 4)).?.asString().chars;
    var file: std.fs.File = undefined;

    file = std.fs.cwd().openFile(path[0 .. path.len - 1], .{}) catch {
        _ = std.fs.cwd().createFile(path[0 .. path.len - 1], .{}) catch {
            return Value.makeError("Unable to open file.", .{});
        };
        const string = obj.ObjString.allocate("", 0);
        return Value.makeObj(@ptrCast(string));
    };
    // if (file.)
    defer file.close();
    const list = obj.ObjList.init();
    const file_contents = file.readToEndAlloc(mem.allocator, 100_000_000) catch {
        return Value.makeError("Unable to read file.", .{});
    };
    var start: usize = 0;
    var end: usize = 0;
    while (end < file_contents.len) : (end += 1) {
        if (file_contents[end] == '\n') {
            const string = obj.ObjString.take(file_contents[start..end], end - start);
            list.append(Value.makeObj(@ptrCast(string)));
            start = end;
        } else if (end == file_contents.len - 1) {
            const string = obj.ObjString.take(file_contents[start..file_contents.len], end - start);
            list.append(Value.makeObj(@ptrCast(string)));
        }
    }
    return Value.makeObj(@ptrCast(list));
}
