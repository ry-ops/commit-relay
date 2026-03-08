#!/bin/bash
#
# Greeting script for commit-relay
# Created by: worker-implementation-017
# Task: test-autonomous-001
#

# Function to display usage
usage() {
    echo "Usage: $0 <name>"
    echo "  name: The name of the person to greet"
    exit 1
}

# Check if name argument is provided
if [ $# -eq 0 ]; then
    echo "Error: Name argument is required"
    usage
fi

# Get the name from the first argument
NAME="$1"

# Print the greeting
echo "Hello, ${NAME}! Welcome to autonomous commit-relay!"
