#!/bin/bash

set -e

TEST_WAR="$TEST_SRCDIR/test/test-war.war"

function assert_war_contains() {
  local needle="$1"
  jar -tf "$TEST_WAR" | grep -sq "$needle" && return 0
  echo "Contents of $TEST_WAR:"
  jar -tf "$TEST_WAR"
  echo "Expected '$needle' in $TEST_WAR"
  return 1
}

assert_war_contains "./WEB-INF/lib/libtest.jar"
assert_war_contains "./WEB-INF/lib/appengine-api.jar"
assert_war_contains "./data/thing1"
