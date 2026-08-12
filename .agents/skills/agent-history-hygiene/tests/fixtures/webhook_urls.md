# webhook URLs fixture

Realistic-shape webhooks that LLMs commonly emit into transcripts/plans
when scaffolding test code. Each line below should match exactly one of
the custom webhook rules added to `assets/gitleaks.toml.template`.

The tokens are synthetic (`a` filler) but match the length and
character-class requirements of each rule's regex. The Stripe value is kept as
a placeholder here and expanded only inside the throwaway test repository, so
GitHub's provider-level secret scanner does not flag this source fixture.
Avoid contiguous
`abcdefghijklmnopqrstuvwxyz` — gitleaks' default global allowlist
treats the full alphabet as a stopword and suppresses any rule match
that contains it.

DISCORD_WEBHOOK=https://discord.com/api/webhooks/123456789012345678/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ZAPIER_HOOK=https://hooks.zapier.com/hooks/catch/12345678/aaaaaaa/
MAKE_HOOK=https://hook.eu1.make.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
INTEGROMAT_HOOK=https://hook.integromat.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STRIPE_WEBHOOK_SECRET=__SYNTHETIC_STRIPE_WEBHOOK_SECRET__
