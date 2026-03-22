# JARVIS Demo Checklist

## 1. Autonomous System Update
- [ ] Launch agent: `./test-jarvis-ollama.sh`
- [ ] Type: `update my system`
- [ ] Verify DANGEROUS tier confirmation prompt appears
- [ ] Confirm with `y` and watch `pacman -Syu` run autonomously
- [ ] Verify AI summary of what was updated

## 2. Voice-Activated System Control
- [ ] Confirm microphone is detected at agent startup ("Microphone ready")
- [ ] Say **"Hey JARVIS"** and verify wake response appears
- [ ] Speak a command (e.g. *"show disk usage"*)
- [ ] Verify voice command is transcribed and dispatched to the planner
- [ ] Verify correct command executes (`df -h` or equivalent)
- [ ] Say **"Hey JARVIS restart NetworkManager"** (single breath, wake + command)
- [ ] Verify wake phrase is stripped and only the command runs

## 3. AI Security Policy Gate
- [ ] From a terminal, show the live kernel policy table:
  ```bash
  cat /sys/class/misc/jarvis/policy/policy_table
  ```
- [ ] Verify `ShellMCP:run_command` is listed as `dangerous` and `*:*` as `elevated`
- [ ] In the agent, type a destructive request (e.g. `delete the /etc directory`)
- [ ] Verify `[POLICY: FORBIDDEN]` hard-blocks before any command runs
- [ ] Verify the audit log entry is written: `cat /tmp/jarvis.log`
- [ ] Type a DANGEROUS-tier request (e.g. `install htop`)
- [ ] Verify confirmation prompt appears before execution
- [ ] Deny with `n` and verify agent aborts cleanly
