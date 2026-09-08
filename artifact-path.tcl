# Path confinement for the artifact routes. The server reads the filesystem as
# the CI service user, and the requested path arrives from the network, so a
# request must never be able to name a file outside the job's own worktree.

# Resolve $rel against $root and return the real file, or raise an error naming
# the reason it was refused.
proc confined-file {root rel} {
    if {$rel eq ""} { return -code error "empty path" }
    if {[file pathtype $rel] ne "relative"} {
        return -code error "path must be relative: $rel"
    }
    foreach seg [file split $rel] {
        if {$seg in {. ..} || [string index $seg 0] eq "~"} {
            return -code error "path must not traverse: $rel"
        }
    }
    set root [file normalize $root]
    # file normalize resolves symlinks among the directories but leaves a final
    # link unresolved, so the leaf is followed here before confinement is tested.
    set real [file normalize [file join $root $rel]]
    for {set hops 0} {$hops < 32 && ![catch {file readlink $real} target]} {incr hops} {
        set real [file normalize [file join [file dirname $real] $target]]
    }
    if {$real ne $root && ![string match "${root}/*" $real]} {
        return -code error "path escapes the job worktree: $rel"
    }
    if {![file isfile $real]} { return -code error "not a file: $rel" }
    return $real
}
