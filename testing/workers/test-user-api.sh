#!/bin/bash

# User Management API Test Script
# Tests all CRUD operations for the new user management endpoints

API_BASE="http://localhost:5001/api"
RESULTS_DIR="./test-results"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create results directory
mkdir -p "$RESULTS_DIR"

echo "=================================================="
echo "User Management API Test Suite"
echo "=================================================="
echo ""

# Test 1: Create a new user
echo -e "${YELLOW}Test 1: Creating a new user${NC}"
response=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/users" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "testuser1",
    "email": "testuser1@example.com",
    "role": "developer",
    "metadata": {"team": "engineering"}
  }')
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "201" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - User created successfully (HTTP $http_code)"
  user_id=$(echo "$body" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
  echo "  User ID: $user_id"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 201, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test1-create-user.json" 2>/dev/null
echo ""

# Test 2: Get all users
echo -e "${YELLOW}Test 2: Getting all users${NC}"
response=$(curl -s -w "\n%{http_code}" "$API_BASE/users")
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "200" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - Retrieved users successfully (HTTP $http_code)"
  user_count=$(echo "$body" | grep -o '"total":[0-9]*' | cut -d':' -f2)
  echo "  Total users: $user_count"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 200, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test2-get-all-users.json" 2>/dev/null
echo ""

# Test 3: Get specific user
echo -e "${YELLOW}Test 3: Getting specific user${NC}"
response=$(curl -s -w "\n%{http_code}" "$API_BASE/users/$user_id")
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "200" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - Retrieved user successfully (HTTP $http_code)"
  username=$(echo "$body" | grep -o '"username":"[^"]*"' | cut -d':' -f2 | tr -d '"')
  echo "  Username: $username"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 200, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test3-get-user.json" 2>/dev/null
echo ""

# Test 4: Update user (PUT)
echo -e "${YELLOW}Test 4: Updating user (PUT)${NC}"
response=$(curl -s -w "\n%{http_code}" -X PUT "$API_BASE/users/$user_id" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "testuser1_updated",
    "email": "testuser1_updated@example.com",
    "role": "admin"
  }')
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "200" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - User updated successfully (HTTP $http_code)"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 200, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test4-update-user.json" 2>/dev/null
echo ""

# Test 5: Partial update (PATCH)
echo -e "${YELLOW}Test 5: Partial update user (PATCH)${NC}"
response=$(curl -s -w "\n%{http_code}" -X PATCH "$API_BASE/users/$user_id" \
  -H "Content-Type: application/json" \
  -d '{
    "metadata": {"department": "platform"}
  }')
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "200" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - User patched successfully (HTTP $http_code)"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 200, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test5-patch-user.json" 2>/dev/null
echo ""

# Test 6: Bulk create users
echo -e "${YELLOW}Test 6: Bulk creating users${NC}"
response=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/users/bulk" \
  -H "Content-Type: application/json" \
  -d '{
    "users": [
      {"username": "alice", "email": "alice@example.com", "role": "developer"},
      {"username": "bob", "email": "bob@example.com", "role": "viewer"},
      {"username": "charlie", "email": "charlie@example.com", "role": "admin"}
    ]
  }')
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "201" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - Bulk users created successfully (HTTP $http_code)"
  created_count=$(echo "$body" | grep -o '"created":[0-9]*' | cut -d':' -f2)
  echo "  Created: $created_count users"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 201, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test6-bulk-create.json" 2>/dev/null
echo ""

# Test 7: Get user statistics
echo -e "${YELLOW}Test 7: Getting user statistics${NC}"
response=$(curl -s -w "\n%{http_code}" "$API_BASE/users/stats")
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "200" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - Retrieved statistics successfully (HTTP $http_code)"
  total=$(echo "$body" | grep -o '"total":[0-9]*' | head -1 | cut -d':' -f2)
  echo "  Total users in system: $total"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 200, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test7-stats.json" 2>/dev/null
echo ""

# Test 8: Search and filter users
echo -e "${YELLOW}Test 8: Search and filter users${NC}"
response=$(curl -s -w "\n%{http_code}" "$API_BASE/users?role=admin&limit=10")
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "200" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - Filtered users successfully (HTTP $http_code)"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 200, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test8-filter.json" 2>/dev/null
echo ""

# Test 9: Soft delete user
echo -e "${YELLOW}Test 9: Soft deleting user${NC}"
response=$(curl -s -w "\n%{http_code}" -X DELETE "$API_BASE/users/$user_id?soft=true")
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "200" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - User soft deleted successfully (HTTP $http_code)"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 200, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test9-soft-delete.json" 2>/dev/null
echo ""

# Test 10: Validation test - invalid email
echo -e "${YELLOW}Test 10: Validation test (invalid email)${NC}"
response=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/users" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "invaliduser",
    "email": "not-an-email",
    "role": "developer"
  }')
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "400" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - Validation correctly rejected invalid email (HTTP $http_code)"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 400, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test10-validation.json" 2>/dev/null
echo ""

# Test 11: Test 404 for non-existent user
echo -e "${YELLOW}Test 11: Testing 404 for non-existent user${NC}"
response=$(curl -s -w "\n%{http_code}" "$API_BASE/users/99999")
http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$http_code" = "404" ]; then
  echo -e "${GREEN}✓ PASSED${NC} - Correctly returned 404 for non-existent user (HTTP $http_code)"
else
  echo -e "${RED}✗ FAILED${NC} - Expected HTTP 404, got $http_code"
fi
echo "$body" | jq '.' > "$RESULTS_DIR/test11-not-found.json" 2>/dev/null
echo ""

echo "=================================================="
echo "Test Suite Completed"
echo "=================================================="
echo "Results saved to: $RESULTS_DIR"
echo ""
