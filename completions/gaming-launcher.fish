# fish completion for gaming-launcher
set -l cmds gaming steam quality secondscreen audio status stop list-games add-game logs benchmark troubleshoot config theme install-completions version help

complete -c gaming-launcher -f
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "gaming"       -d "start isolated gaming session"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "steam"        -d "session for Steam Big Picture"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "quality"      -d "show/switch quality profile"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "secondscreen" -d "Moonlight client as an extra monitor"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "audio"        -d "headset loopback / sink state"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "status"       -d "session status"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "stop"         -d "tear everything down"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "list-games"   -d "installed Steam games"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "add-game"     -d "add a Sunshine app entry"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "logs"         -d "tail/analyse logs"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "benchmark"    -d "VA-API / capture probe"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "troubleshoot" -d "run diagnostics"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "config"       -d "show/edit config"
complete -c gaming-launcher -n "not __fish_seen_subcommand_from $cmds" -a "theme"        -d "reskin the Sunshine web UI"

complete -c gaming-launcher -n "__fish_seen_subcommand_from quality gaming steam" -l profile -x -a "gaming custom"
complete -c gaming-launcher -n "__fish_seen_subcommand_from quality" -l auto -x -a "on off"
complete -c gaming-launcher -n "__fish_seen_subcommand_from gaming secondscreen" -l res -x
complete -c gaming-launcher -n "__fish_seen_subcommand_from gaming secondscreen" -l fps -x
complete -c gaming-launcher -n "__fish_seen_subcommand_from secondscreen" -a "on off status right left up down"
complete -c gaming-launcher -n "__fish_seen_subcommand_from audio" -a "headset status restore"
complete -c gaming-launcher -n "__fish_seen_subcommand_from troubleshoot" -a "hardware audio input latency"
complete -c gaming-launcher -n "__fish_seen_subcommand_from config" -a "show edit path"
complete -c gaming-launcher -n "__fish_seen_subcommand_from theme" -a "apply revert status"
complete -c gaming-launcher -n "__fish_seen_subcommand_from logs" -a "analyze"
complete -c gaming-launcher -n "__fish_seen_subcommand_from add-game run gaming" -l gamescope    -d "wrap the game in gamescope"
complete -c gaming-launcher -n "__fish_seen_subcommand_from add-game run gaming" -l no-gamescope -d "do not wrap in gamescope"
complete -c gaming-launcher -n "__fish_seen_subcommand_from add-game run" -l direct -d "launch the game directly (skip Big Picture)"
