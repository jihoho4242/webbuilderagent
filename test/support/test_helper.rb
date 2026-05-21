# frozen_string_literal: true

require "minitest/autorun"

AIWEB_TEST_REPO_ROOT = File.expand_path("../..", __dir__) unless defined?(AIWEB_TEST_REPO_ROOT)
AIWEB_TEST_LIB_DIR = File.join(AIWEB_TEST_REPO_ROOT, "lib") unless defined?(AIWEB_TEST_LIB_DIR)

$LOAD_PATH.unshift(AIWEB_TEST_LIB_DIR) unless $LOAD_PATH.include?(AIWEB_TEST_LIB_DIR)
