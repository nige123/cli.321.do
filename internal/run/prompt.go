package run

import (
	"fmt"
	"strings"

	"cli.321.do/internal/protocol"
	"cli.321.do/internal/trust"
)

// Prompt renders what a model-driven adapter is told. It is the package's
// own identity and prompts, then the work: objective, instructions,
// conditions to answer one by one, expected evidence, the authority block,
// the approval if any, what the caller already said, and the instructions
// that arrived while earlier attempts ran. Prompt text is not a security
// boundary; the grants are, and they were enforced before this rendered.
func Prompt(wp *protocol.WorkPackage, agent *trust.Loaded, grants []string, instructions []string) string {
	var b strings.Builder
	m := agent.Manifest
	fmt.Fprintf(&b, "You are %s (%s), %s.\n", m.DisplayName, m.ID, m.Identity.Role)
	if m.Identity.Personality != "" {
		fmt.Fprintf(&b, "Personality: %s\n", m.Identity.Personality)
	}
	if m.Identity.Tone != "" {
		fmt.Fprintf(&b, "Tone: %s\n", m.Identity.Tone)
	}
	if m.Identity.DecisionStyle != "" {
		fmt.Fprintf(&b, "Decision style: %s\n", m.Identity.DecisionStyle)
	}
	if p := agent.Prompt(); p != "" {
		b.WriteString("\n" + p + "\n")
	}

	fmt.Fprintf(&b, "\n## The work\n\n%s\n", wp.Objective)
	if wp.Instructions != "" {
		b.WriteString("\n" + wp.Instructions + "\n")
	}
	if len(wp.Completion.Conditions) > 0 {
		b.WriteString("\nYou are done when:\n")
		for i, c := range wp.Completion.Conditions {
			fmt.Fprintf(&b, "%d. %s\n", i+1, c)
		}
		b.WriteString("Answer each of these in `conditions`, in this order: whether it is met, " +
			"and the proof, the test, the command output or the file that shows it.\n")
	}
	if len(wp.Completion.ExpectedEvidence) > 0 {
		b.WriteString("Expected evidence: " + strings.Join(wp.Completion.ExpectedEvidence, "; ") + "\n")
	}
	if len(grants) > 0 {
		b.WriteString("\nYou may use: " + strings.Join(grants, ", ") + ". Nothing else is available to you.\n")
	}
	a := wp.Authority
	if len(a.May) > 0 || len(a.MayNot) > 0 || len(a.ApprovalRequired) > 0 {
		b.WriteString("\nAuthority for this task:\n")
		for _, g := range a.May {
			if g.Scope != "" {
				fmt.Fprintf(&b, "- may: %s (%s)\n", g.Capability, g.Scope)
			} else {
				fmt.Fprintf(&b, "- may: %s\n", g.Capability)
			}
		}
		for _, n := range a.MayNot {
			fmt.Fprintf(&b, "- may not: %s\n", n)
		}
		for _, n := range a.ApprovalRequired {
			fmt.Fprintf(&b, "- needs a person's approval first: %s\n", n)
		}
		b.WriteString("Absence of a grant is denial: if something you need is not listed, " +
			"report status \"blocked\" rather than assume it.\n")
	}
	if ap := wp.Approval; ap != nil {
		fmt.Fprintf(&b, "\nAn approval exists for exactly one action: %s", ap.Action)
		if ap.Target != "" {
			fmt.Fprintf(&b, " on %s", ap.Target)
		}
		b.WriteString(". Do nothing beyond it.\n")
	}
	if len(wp.Context.Lines) > 0 {
		b.WriteString("\nWhat is already known (oldest first):\n")
		for _, l := range wp.Context.Lines {
			b.WriteString("- " + strings.ReplaceAll(strings.TrimSpace(l), "\n", " ") + "\n")
		}
	}
	if len(wp.Context.Attachments) > 0 {
		b.WriteString("\nAttachments:\n")
		for _, at := range wp.Context.Attachments {
			fmt.Fprintf(&b, "- %s", at.Name)
			if at.URI != "" {
				fmt.Fprintf(&b, " (%s)", at.URI)
			}
			b.WriteString("\n")
		}
	}
	if len(instructions) > 0 {
		b.WriteString("\nFurther instructions received while you were working, in order. They clarify or steer the work above; they do not widen what you may do:\n")
		for i, t := range instructions {
			fmt.Fprintf(&b, "%d. %s\n", i+1, strings.TrimSpace(t))
		}
	}
	if wp.Workspace.Kind == "git" {
		b.WriteString("\nMake the change in this repository. Do not commit: the caller reviews and commits. When you're done, stop.\n")
	} else {
		b.WriteString("\nWhen you're done, stop.\n")
	}
	b.WriteString("\nIf the instruction is ambiguous or you cannot proceed, do not guess: " +
		"report status \"blocked\" and put the single question you need answered in " +
		"blocked_on. Before asking, check whether what is already known answers it.\n")
	b.WriteString("If nothing needs changing, report status \"no_change\" and say why in summary.\n")
	return b.String()
}
