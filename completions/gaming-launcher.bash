# bash completion for gaming-launcher
_gaming_launcher() {
    local cur prev cmds
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmds="gaming steam quality secondscreen audio status stop list-games add-game logs benchmark troubleshoot theme config session-up session-run session-down install-completions version help"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ); return
    fi
    case "$prev" in
        --profile|-p) COMPREPLY=( $(compgen -W "gaming custom" -- "$cur") ); return;;
        --auto)       COMPREPLY=( $(compgen -W "on off" -- "$cur") ); return;;
        quality)      COMPREPLY=( $(compgen -W "gaming custom --auto" -- "$cur") ); return;;
        secondscreen) COMPREPLY=( $(compgen -W "on off status right left up down --res --fps" -- "$cur") ); return;;
        audio)        COMPREPLY=( $(compgen -W "headset status restore" -- "$cur") ); return;;
        troubleshoot) COMPREPLY=( $(compgen -W "hardware audio input latency" -- "$cur") ); return;;
        config)       COMPREPLY=( $(compgen -W "show edit path" -- "$cur") ); return;;
        theme)        COMPREPLY=( $(compgen -W "apply revert status" -- "$cur") ); return;;
        logs)         COMPREPLY=( $(compgen -W "analyze" -- "$cur") ); return;;
    esac
    COMPREPLY=( $(compgen -W "--profile --res --fps --auto --debug" -- "$cur") )
}
complete -F _gaming_launcher gaming-launcher
