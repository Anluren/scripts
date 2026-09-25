#!/usr/bin/env bash
#
# Register LLVM toolchains under /usr/lib/llvm-<version> with
# update-alternatives, using `clang` as the master link and every other
# non-versioned tool in <prefix>/bin as a slave.
#
# Usage:
#   llvm-alternatives.sh install [OPTIONS] [VERSION ...]
#   llvm-alternatives.sh set [OPTIONS] <VERSION>
#   llvm-alternatives.sh remove [OPTIONS] [VERSION ...]
#   llvm-alternatives.sh list
#   llvm-alternatives.sh detail
#
# Options:
#   -v, --version VER   Version to act on. Repeatable and comma-separated.
#                       The value "all" selects every detected version.
#                       install/remove default to all when none is given.
#   -p, --priority NUM  Alternative priority for install. Defaults to the
#                       version number (e.g. 23, 18). install only.
#   -d, --detail        Dump every master/slave symlink in the group. Usable
#                       as a standalone command, or as a flag after any other
#                       command (e.g. install -d -v 23) to dump the result.
#   -h, --help          Show this help.
#
# Environment:
#   LLVM_ROOT   Root containing llvm-<version> dirs (default: /usr/lib)
#   BIN_DIR     Where master/slave links are placed (default: /usr/bin)

set -euo pipefail

LLVM_ROOT="${LLVM_ROOT:-/usr/lib}"
BIN_DIR="${BIN_DIR:-/usr/bin}"
MASTER_NAME="clang"

info() { printf '[info] %s\n' "$*"; }
error() {
    printf '[error] %s\n' "$*" >&2
    exit 1
}

usage() {
    awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# installed_versions — list version numbers of /usr/lib/llvm-<version> dirs
installed_versions() {
    local dir version
    for dir in "$LLVM_ROOT"/llvm-*; do
        [ -d "$dir" ] || continue
        version="${dir##*-}"
        case "$version" in
            *[!0-9]*) continue ;; # skip non-numeric suffixes
        esac
        printf '%s\n' "$version"
    done
}

# version_from_arg — validate and normalize a version argument
version_from_arg() {
    local v="$1" master
    master="$LLVM_ROOT/llvm-$v/bin/$MASTER_NAME"
    [ -x "$master" ] || error "no $MASTER_NAME in $LLVM_ROOT/llvm-$v/bin"
    printf '%s\n' "$v"
}

# collect_versions <spec...> — validate specs, expand "all", de-duplicate
collect_versions() {
    local specs=("$@") spec v
    if [ "${#specs[@]}" -eq 0 ]; then
        mapfile -t specs < <(installed_versions)
    fi
    local -A seen=()
    for spec in "${specs[@]}"; do
        if [ "$spec" = "all" ]; then
            while IFS= read -r v; do
                [ -n "${seen[$v]+x}" ] && continue
                seen[$v]=1
                printf '%s\n' "$v"
            done < <(installed_versions)
        else
            v="$(version_from_arg "$spec")"
            [ -n "${seen[$v]+x}" ] && continue
            seen[$v]=1
            printf '%s\n' "$v"
        fi
    done
}

# build_slaves <version> — emit --slave args for every non-versioned tool
build_slaves() {
    local version="$1" bindir tool name
    bindir="$LLVM_ROOT/llvm-$version/bin"
    for tool in "$bindir"/*; do
        [ -x "$tool" ] || continue
        name="${tool##*/}"
        case "$name" in
            "$MASTER_NAME") continue ;; # master, handled separately
        esac
        # skip versioned tools such as clang-18, lldb-server-23, lldb-server-23.1.2
        case "$name" in
            *-[0-9]*) continue ;;
        esac
        printf '%s\n' --slave
        printf '%s\n' "$BIN_DIR/$name"
        printf '%s\n' "$name"
        printf '%s\n' "$tool"
    done
}

do_install() {
    [ "$(id -u)" -eq 0 ] || error "must be run as root"
    local priority="${1:-}"
    shift
    if [ -n "$priority" ]; then
        case "$priority" in
            *[!0-9]*|"") error "invalid priority: $priority" ;;
        esac
    fi
    local version versions
    mapfile -t versions < <(collect_versions "$@")
    [ "${#versions[@]}" -gt 0 ] || error "no LLVM toolchains found under $LLVM_ROOT"

    for version in "${versions[@]}"; do
        local bindir="$LLVM_ROOT/llvm-$version/bin"
        local master="$bindir/$MASTER_NAME"
        local pri="${priority:-$version}"

        info "registering LLVM $version ($master) as '$MASTER_NAME' (priority $pri)"
        mapfile -t slaves < <(build_slaves "$version")
        update-alternatives --install \
            "$BIN_DIR/$MASTER_NAME" "$MASTER_NAME" "$master" "$pri" \
            "${slaves[@]}"
    done
}

do_set() {
    [ "$(id -u)" -eq 0 ] || error "must be run as root"
    [ $# -gt 0 ] || error "set requires a version (e.g. set -v 18)"
    local version versions
    mapfile -t versions < <(collect_versions "$@")
    [ "${#versions[@]}" -eq 1 ] || error "set requires exactly one version (got ${#versions[@]})"
    version="${versions[0]}"
    info "setting default '$MASTER_NAME' to LLVM $version"
    update-alternatives --set "$MASTER_NAME" "$LLVM_ROOT/llvm-$version/bin/$MASTER_NAME"
}

do_remove() {
    [ "$(id -u)" -eq 0 ] || error "must be run as root"
    local version versions
    mapfile -t versions < <(collect_versions "$@")

    for version in "${versions[@]}"; do
        info "removing LLVM $version"
        update-alternatives --remove "$MASTER_NAME" "$LLVM_ROOT/llvm-$version/bin/$MASTER_NAME"
    done
}

do_list() {
    update-alternatives --display "$MASTER_NAME"
}

# link_chain <path> — print a symlink resolution chain (path -> ... -> target)
link_chain() {
    local p="$1" out="$1" target
    while [ -L "$p" ]; do
        target="$(readlink "$p")"
        case "$target" in
            /*) p="$target" ;;
            *)  p="$(dirname "$p")/$target" ;;
        esac
        out="$out -> $p"
    done
    printf '%s\n' "$out"
}

# do_detail — dump every master/slave symlink managed by this group
do_detail() {
    local out value link
    out="$(update-alternatives --query "$MASTER_NAME" 2>/dev/null)" ||
        error "no '$MASTER_NAME' alternatives registered"

    value="$(printf '%s\n' "$out" | awk '/^Value:/ { print $2; exit }')"

    local links=()
    link="$(printf '%s\n' "$out" | awk '/^Link:/ { print $2; exit }')"
    links+=("$link")

    # slave links from the header "Slaves:" block (each line: <name> <link>)
    while IFS= read -r l; do
        [ -n "$l" ] && links+=("$l")
    done < <(printf '%s\n' "$out" | awk '
        /^Status:/ { done = 1; in_slaves = 0 }
        done { next }
        /^Slaves:/ { in_slaves = 1; next }
        in_slaves && NF >= 2 { print $2 }
    ')

    [ -n "$value" ] && printf '%-16s %s\n' 'active:' "$value"
    printf '%-16s %s\n' 'master:' "$MASTER_NAME"
    printf '\n'

    local i
    for i in "${!links[@]}"; do
        if [ -L "${links[$i]}" ]; then
            link_chain "${links[$i]}"
        else
            printf '%s (missing)\n' "${links[$i]}"
        fi
    done
}

main() {
    local cmd="${1:-}"
    [ -n "$cmd" ] || usage
    shift

    local priority="" detail=0 specs=() a v
    while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
            -d|--detail)
                detail=1
                shift
                ;;
            -p|--priority)
                [ -n "${2:-}" ] || error "$a requires an argument"
                priority="$2"
                shift 2
                ;;
            --priority=*)
                priority="${a#*=}"
                shift
                ;;
            -v|--version)
                [ -n "${2:-}" ] || error "$a requires an argument"
                IFS=',' read -ra vs <<< "$2"
                for v in "${vs[@]}"; do specs+=("$v"); done
                shift 2
                ;;
            --version=*)
                IFS=',' read -ra vs <<< "${a#*=}"
                for v in "${vs[@]}"; do specs+=("$v"); done
                shift
                ;;
            -*) error "unknown option: $a" ;;
            *) specs+=("$a"); shift ;;
        esac
    done

    case "$cmd" in
        install) do_install "$priority" "${specs[@]}" ;;
        set)
            [ -z "$priority" ] || error "--priority only applies to install"
            do_set "${specs[@]}"
            ;;
        remove)
            [ -z "$priority" ] || error "--priority only applies to install"
            do_remove "${specs[@]}"
            ;;
        list)
            [ -z "$priority" ] || error "--priority only applies to install"
            do_list
            ;;
        detail|-d|--detail)
            [ -z "$priority" ] || error "--priority only applies to install"
            do_detail
            ;;
        -h|--help|help) usage ;;
        *) usage ;;
    esac

    if [ "$detail" -eq 1 ]; then
        do_detail
    fi
}

main "$@"
