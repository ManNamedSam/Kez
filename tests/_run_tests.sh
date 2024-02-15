#!/bin/bash


TEST_FOLDER="./tests"
TEST_PATTERN="*.kez"  
TEST_RUNNER="./zig-out/bin/kez"  

# Check if the test folder exists
if [[ ! -d "$TEST_FOLDER" ]]; then
  echo "Error: Test folder '$TEST_FOLDER' does not exist."
  exit 1
fi

# Find all test files based on the pattern
test_files=$(find "$TEST_FOLDER" -type f -name "$TEST_PATTERN")

# Check if any test files were found
if [[ -z "$test_files" ]]; then
  echo "No test files found in '$TEST_FOLDER'."
  exit 0
fi

# Run each test file with appropriate commands
for test_file in $test_files; do
  echo "Running test file: $test_file"

  # Use your test runner/interpreter or custom commands here
  # Replace with the correct command according to your language and setup
  if [[ -n "$TEST_RUNNER" ]]; then
    $TEST_RUNNER "$test_file"
  else
    # Example for running Python test files without a test runner
    python "$test_file"
  fi

  # Capture and handle output according to your requirements
  # Add logic to parse output, collect pass/fail results, write to logs, etc.
done

# Report overall test results
# Add code to summarize pass/fail counts, display messages, etc.

echo "Test suite completed."