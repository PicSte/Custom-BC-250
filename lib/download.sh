# shellcheck shell=bash
#
# Fetching upstream sources, pinned.
#
# Everything this tool downloads ends up running as root, so nothing is ever
# pulled from a moving branch. Single files are pinned by sha256; git
# checkouts are pinned by commit id, which is itself a content hash. A
# mismatch aborts rather than falling back.

# src_get <NAME> <FIELD> — reads SRC_<NAME>_<FIELD> from sources.env.
src_get() {
	local var="SRC_${1}_${2}"
	printf '%s\n' "${!var-}"
}

src_dir() {
	printf '%s\n' "${BC250_SRC}/$(tr '[:upper:]_' '[:lower:]-' <<<"$1")"
}

_sha256() { sha256sum -- "$1" | cut -d' ' -f1; }

# src_file <NAME> — downloads the pinned file and prints its path.
#
# A file already present with the right checksum is left alone, which makes
# every module's install step idempotent and offline-friendly on re-runs.
src_file() {
	local name=$1 url sha dest dir got
	url=$(src_get "$name" URL)
	sha=$(src_get "$name" SHA256)
	[[ -n $url ]] || die "sources.env has no URL for $name"
	[[ -n $sha ]] || die "sources.env has no SHA256 for $name — refusing to fetch unpinned code"

	dir=$(src_dir "$name")
	dest="$dir/$(basename "$url")"

	if [[ -f $dest ]] && [[ $(_sha256 "$dest") == "$sha" ]]; then
		log_debug "$name already present and verified"
		printf '%s\n' "$dest"
		return 0
	fi

	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		log_debug "[dry-run] would fetch $url -> $dest"
		printf '%s\n' "$dest"
		return 0
	fi

	mkdir -p -- "$dir"
	log_info "fetching $name"
	curl -fsSL --retry 3 --retry-delay 2 -o "$dest.part" -- "$url" ||
		die "download failed: $url"

	got=$(_sha256 "$dest.part")
	if [[ $got != "$sha" ]]; then
		rm -f -- "$dest.part"
		die "checksum mismatch for $name"$'\n'"  expected $sha"$'\n'"  got      $got"$'\n' \
		    "Upstream changed under a pinned URL. Do not run it; update sources.env deliberately."
	fi

	mv -- "$dest.part" "$dest"
	[[ $dest == *.sh ]] && chmod 0755 -- "$dest"
	printf '%s\n' "$dest"
}

# src_git <NAME> — clones or updates to the pinned commit, prints the path.
src_git() {
	local name=$1 url ref dir head
	url=$(src_get "$name" URL)
	ref=$(src_get "$name" REF)
	[[ -n $url ]] || die "sources.env has no URL for $name"
	[[ $ref =~ ^[0-9a-f]{40}$ ]] ||
		die "sources.env REF for $name must be a full 40-character commit id, got '$ref'"

	dir=$(src_dir "$name")

	if [[ ${BC250_DRY_RUN:-0} == 1 ]]; then
		log_debug "[dry-run] would check out $url at $ref -> $dir"
		printf '%s\n' "$dir"
		return 0
	fi

	if [[ -d $dir/.git ]]; then
		head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
		if [[ $head == "$ref" ]]; then
			log_debug "$name already at $ref"
			printf '%s\n' "$dir"
			return 0
		fi
	else
		mkdir -p -- "$(dirname -- "$dir")"
		rm -rf -- "$dir"
		log_info "cloning $name"
		git clone --quiet -- "$url" "$dir" || die "clone failed: $url"
	fi

	log_info "checking out $name at ${ref:0:12}"
	git -C "$dir" fetch --quiet origin "$ref" 2>/dev/null || git -C "$dir" fetch --quiet origin
	git -C "$dir" checkout --quiet "$ref" || die "no such commit in $name: $ref"

	head=$(git -C "$dir" rev-parse HEAD)
	[[ $head == "$ref" ]] || die "checkout verification failed for $name: at $head, wanted $ref"

	printf '%s\n' "$dir"
}
