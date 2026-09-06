#!/usr/bin/env bats
#
# Pinned sources. Everything fetched here runs as root, so a moving target or
# a changed file has to be an error, never a shrug.

load helper

setup() { sandbox_setup; lib_source; }

@test "a file is fetched and its checksum verified" {
	# src_file prints the path on stdout and logs on stderr, so take stdout.
	local path
	path=$(src_file CU_LIVE_MANAGER 2>/dev/null)
	[ -f "$path" ]
	[ "$(sha256sum -- "$path" | cut -d' ' -f1)" = "$SRC_CU_LIVE_MANAGER_SHA256" ]
}

@test "a checksum mismatch aborts instead of using the file" {
	SRC_CU_LIVE_MANAGER_SHA256=$(printf 'a%.0s' {1..64})
	run src_file CU_LIVE_MANAGER
	[ "$status" -ne 0 ]
	[[ $output == *"checksum mismatch"* ]]
	[[ $output == *"Do not run it"* ]]
	# Nothing half-downloaded is left behind.
	[ ! -f "$(src_dir CU_LIVE_MANAGER)/bc250-cu-live-manager" ]
}

@test "an unpinned source is refused outright" {
	SRC_CU_LIVE_MANAGER_SHA256=''
	run src_file CU_LIVE_MANAGER
	[ "$status" -ne 0 ]
	[[ $output == *"refusing to fetch unpinned code"* ]]
}

@test "an already-verified file is not fetched again" {
	src_file CU_LIVE_MANAGER >/dev/null
	: >"$MOCK_STATE/calls"
	run src_file CU_LIVE_MANAGER
	[ "$status" -eq 0 ]
	# The curl mock logs nothing, so assert on the marker it would have made.
	[ ! -f "$(src_dir CU_LIVE_MANAGER)/bc250-cu-live-manager.part" ]
}

@test "a git source must be pinned to a full commit id" {
	SRC_SMU_OC_REF=main
	run src_git SMU_OC
	[ "$status" -ne 0 ]
	[[ $output == *"40-character commit id"* ]]
}

@test "a git source is checked out at exactly the pinned commit" {
	local repo="$BATS_TEST_TMPDIR/upstream"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email t@example.invalid
	git -C "$repo" config user.name test
	echo one >"$repo/file"
	git -C "$repo" add -A && git -C "$repo" commit -qm one
	local first; first=$(git -C "$repo" rev-parse HEAD)
	echo two >"$repo/file"
	git -C "$repo" commit -qam two

	SRC_SMU_OC_URL="$repo"
	SRC_SMU_OC_REF="$first"
	local out
	out=$(src_git SMU_OC 2>/dev/null)
	[ "$(git -C "$out" rev-parse HEAD)" = "$first" ]
	[ "$(cat "$out/file")" = one ]
}

@test "a commit that is not in the repository is an error" {
	local repo="$BATS_TEST_TMPDIR/upstream"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email t@example.invalid
	git -C "$repo" config user.name test
	echo one >"$repo/file"
	git -C "$repo" add -A && git -C "$repo" commit -qm one

	SRC_SMU_OC_URL="$repo"
	SRC_SMU_OC_REF=$(printf 'b%.0s' {1..40})
	run src_git SMU_OC
	[ "$status" -ne 0 ]
}

@test "'bc250ctl sources' reports what is pinned" {
	run bc250ctl sources
	[ "$status" -eq 0 ]
	[[ $output == *CU_LIVE_MANAGER* ]]
	[[ $output == *"pinned at"* ]]
}
