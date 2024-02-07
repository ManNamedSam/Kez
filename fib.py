import time

memo = dict()


def fib(n):
    """Calculates the nth Fibonacci number using recursion."""
    if n < 2:
        return n
    try:
        return memo[n]
    except:

        a = fib(n - 2) + fib(n - 1)
        memo[n] = a
        return a


start = time.time()  # Start the timer
result = fib(100)
end = time.time()  # Stop the timer

print(result)
print(f"Time taken: {end - start:.4f} seconds")

string = "hello"

assert string == "goodbye"

print("hello world")
