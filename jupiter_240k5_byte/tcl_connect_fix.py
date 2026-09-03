import re, sys
# Rewrites the state-lossy insert tcl's rigid net-joins into net-or-pin
# conditional connects. The original form
#   connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins A]] <pin args...>
# aborts the whole script when pin A has no net (jupiter byte-DMA wiring leaves
# several sync pins dangling by design), losing the modem insertion.
# The WHOLE remainder of the line (one or more pin args) is preserved on both
# branches. Idempotent.
p = sys.argv[1]
s = open(p).read()
if 'llength [get_bd_nets -quiet' in s:
    sys.exit(0)
pat = re.compile(r'^connect_bd_net -net \[get_bd_nets -of_objects \[get_bd_pins ([^\]]+)\]\] (.+)$', re.M)
def rep(m):
    a, rest = m.group(1), m.group(2)
    return ('if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins %s]]]} '
            '{ connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins %s]] %s } '
            'else { connect_bd_net [get_bd_pins %s] %s }' % (a, a, rest, a, rest))
ns = pat.sub(rep, s)
# The degraded generation also TRUNCATES the tcl: the in-session (v3) version
# ends with validate/save/constraints/close/exit; without save_bd_design the
# in-memory modem insertion is silently discarded at vivado exit.
if 'save_bd_design' not in ns:
    ns = ns.rstrip('\n') + (
        '\nvalidate_bd_design'
        '\nsave_bd_design'
        '\nadd_files -fileset constrs_1 -norecurse projects/jupiter_sdr/system_constr.xdc'
        '\nclose_project'
        '\nexit\n')
if ns != s:
    open(p, 'w').write(ns)
    print('CONNECT_FIX applied')
