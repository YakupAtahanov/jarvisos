# JARVIS Demo Checklist

## 1. Autonomous System Update
- [ ] Say **"Hey JARVIS"** — verify Konsole opens with JARVIS running
- [ ] Speak or type: `update my system`
- [ ] Verify DANGEROUS tier confirmation prompt appears
- [ ] Confirm with `y` and watch `pacman -Syu` run autonomously
- [ ] Verify AI summary of what was updated (spoken via piper TTS + shown in terminal)

## 2. Voice-Activated System Control
- [ ] Say **"Hey JARVIS"** — verify Konsole opens and JARVIS speaks a greeting
- [ ] Speak a command (e.g. *"show disk usage"*)
- [ ] Verify voice command is transcribed and dispatched to the planner
- [ ] Verify correct command executes (`df -h` or equivalent) and result is spoken back
- [ ] Say **"Hey JARVIS restart NetworkManager"** (single breath, wake + command)
- [ ] Verify wake phrase is stripped and only the command runs

## 3. AI Security Policy Gate
- [ ] Say **"Hey JARVIS"** to open session, then from a second terminal show the live kernel policy table:
  ```bash
  cat /sys/class/misc/jarvis/policy/policy_table
  ```
- [ ] Verify `ShellMCP:run_command` is listed as `dangerous` and `*:*` as `elevated`
- [ ] Speak or type a destructive request (e.g. `delete the /etc directory`)
- [ ] Verify `[POLICY: FORBIDDEN]` hard-blocks before any command runs
- [ ] Verify the audit log entry is written: `cat /tmp/jarvis.log`
- [ ] Speak or type a DANGEROUS-tier request (e.g. `install htop`)
- [ ] Verify confirmation prompt appears before execution
- [ ] Deny with `n` and verify agent aborts cleanly

---
> **Fallback**: All demos can also be driven by typing directly in the Konsole window if voice is unavailable.
