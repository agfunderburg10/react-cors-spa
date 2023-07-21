PROJECT_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

update-terraform-lock:
	terraform providers lock -platform=darwin_arm64 -platform=linux_arm64 -platform=linux_amd64
