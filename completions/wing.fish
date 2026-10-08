# fish completion for wing.

function __wing_current_is_option
    string match -q -- '-*' (commandline -ct)
end

complete -c wing -n 'test (count (commandline -opc)[2..-1]) -eq 0; and not __wing_current_is_option' -f -a 'get ls push read registry rm update write'
complete -c wing -n 'string match -q -- "@*" (commandline -ct)' -f -a '(begin; test -f wing.yaml; and awk "/^registries:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [A-Za-z0-9_-]+:/{sub(/^  /,\"@\");sub(/:.*/,\"\");print}" wing.yaml | sort -u; end)'
complete -c wing -n '__fish_seen_subcommand_from registry; and __fish_seen_subcommand_from set' -f -a '(begin; test -f wing.yaml; and awk "/^registries:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [A-Za-z0-9_-]+:/{sub(/^  /,\"\");sub(/:.*/,\"\");print}" wing.yaml | sort -u; end)'

complete -c wing -n '__wing_current_is_option' -l registry -d 'Schema Registry URL' -x
complete -c wing -n '__wing_current_is_option' -l config -d 'Read this configuration file' -r
complete -c wing -n '__wing_current_is_option' -l schema-dir -d 'Offline schema cache directory' -r
complete -c wing -n '__wing_current_is_option' -l errors -d 'Diagnostic format' -x
complete -c wing -n '__fish_seen_argument -l errors' -f -a 'json'
complete -c wing -n '__wing_current_is_option' -s q -l quiet -d 'Suppress summaries'
complete -c wing -n '__wing_current_is_option' -s v -l verbose -d 'Verbose diagnostics'
complete -c wing -n '__wing_current_is_option' -s h -l help -d 'Show help'
complete -c wing -n '__wing_current_is_option' -s V -l version -d 'Print version'
complete -c wing -n '__fish_seen_argument -l config' -F
complete -c wing -n '__fish_seen_argument -l schema-dir' -F

complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from read' -l check -d 'Validate without changing records'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from write' -l fit -d 'Fit records to the selected schema'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from write' -l check -d 'Validate without writing'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from ls' -l key -d 'List key schemas'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from ls' -l json -d 'Print JSON'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from get' -l meta -d 'Print registry metadata'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from get' -l key -d 'Fetch key schema'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from push' -l check -d 'Lint without registering'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from push' -l fixtures -d 'Validate fixture directory' -r
complete -c wing -n '__fish_seen_argument -l fixtures; and __fish_seen_subcommand_from push' -F
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from push' -l compat -d 'Temporary compatibility level' -x
complete -c wing -n '__fish_seen_argument -l compat; and __fish_seen_subcommand_from push' -f -a 'BACKWARD BACKWARD_TRANSITIVE FORWARD FORWARD_TRANSITIVE FULL FULL_TRANSITIVE NONE'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from push' -l meta -d 'Read a metadata envelope'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from push' -l key -d 'Register a key schema'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from rm' -s y -l yes -d 'Delete without confirming'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from rm' -l permanent -d 'Delete permanently'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from rm' -l key -d 'Delete key schema'
complete -c wing -n '__fish_seen_subcommand_from registry; and test (count (commandline -opc)[3..-1]) -eq 0; and not __wing_current_is_option' -f -a 'list set init'
complete -c wing -n '__wing_current_is_option; and __fish_seen_subcommand_from registry; and __fish_seen_subcommand_from list' -l json -d 'Print JSON'
complete -c wing -n '__fish_seen_subcommand_from update' -f
