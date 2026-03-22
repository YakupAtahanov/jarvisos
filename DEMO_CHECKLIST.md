# JARVIS Demo Checklist

## Setup
- [ ] Run `./test-jarvis-ollama.sh` from the repo root
- [ ] Wait for script to verify deps, Ollama, and model — new Konsole window opens with JARVIS running
- [ ] Confirm agent banner is visible and model name is shown

## 1. Autonomous System Update
- [ ] Type: `update my system`
- [ ] Verify DANGEROUS tier confirmation prompt appears
- [ ] Confirm with `y` and watch `pacman -Syu` run autonomously
- [ ] Verify AI summary of what was updated is printed in terminal

## 2. System Control Command
- [ ] Type: `show disk usage`
- [ ] Verify `df -h` (or equivalent) runs and output is shown
- [ ] Verify AI summarises the result in plain English

## 3. AI Security Policy Gate
- [ ] Type a destructive request (e.g. `delete the /etc directory`)
- [ ] Verify `[POLICY: FORBIDDEN]` hard-blocks before any command runs
- [ ] Type a DANGEROUS-tier request (e.g. `install htop`)
- [ ] Verify confirmation prompt appears
- [ ] Deny with `n` and verify agent aborts cleanly

---
> **Fallback**: If voice is unavailable, all steps above use typed input — the script handles text-only mode automatically.
