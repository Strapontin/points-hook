.PHONY: coverage

# Generates lcov.info at the project root
coverage:
	forge coverage --report lcov --report-file lcov.info
