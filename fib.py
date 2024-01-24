import time


def fib(n):
    """Calculates the nth Fibonacci number using recursion."""
    if n < 2:
        return n
    else:
        return fib(n - 2) + fib(n - 1)


start = time.time()  # Start the timer
result = fib(35)
end = time.time()  # Stop the timer

print(result)
print(f"Time taken: {end - start:.4f} seconds")
