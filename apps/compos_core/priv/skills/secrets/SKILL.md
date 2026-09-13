---
name: secrets
description: Probe the secret providers on this machine and set a key up through the key chain. Load before registering a key or debugging one that resolves empty.
---

# Set up secrets

A key never goes into a config file. Config holds an `@NAME` reference, and
the chain in `keys.scm` resolves it at the moment of use, so the value stays
in the provider. `(key-resolve V)` is that one resolution point: `"@VAR"`
becomes the secret, a list of parts joins after each resolves, and anything
else passes through unchanged.

## Probe before you advise

`(setup-secret-scan)` answers `(NAME INSTALLED? READY? HINT)` for Doppler,
1Password, GPG, the macOS Keychain, and the Linux Secret Service.
`(setup-secrets-ready)` is the short list of providers that can actually
answer for a key.

Installed and ready are different facts, and the difference is the whole
reason to probe. An installed Doppler that was never logged in resolves
every reference to empty, and the failure reads as a broken key rather than
a missing login. Say which of the two is wrong before suggesting a fix.

## What a probe may do

Local, non-interactive, and value-free. A probe must not unlock a vault,
call the network, or print a secret: its output is tested and discarded.
Never put a resolved value in a buffer, a message, or a transcript, and
never echo one back to the user to confirm it.

An answer can be present and still mean no. `grep -c` says `0`, and
`op account list --format=json` says `[]` when no account is configured.
`*setup-probe-empties*` holds that set; extend it rather than writing a
special case per provider.

## Registering a key

`(llm-key PROVIDER)` answers the resolved key for a provider id, or `#f`
when it is unregistered. `(register-llm-key! PROVIDER VALUE)` sets an
explicit one, and `(register-llm-base-url! PROVIDER VALUE)` points a
provider at a self-hosted OpenAI-compatible server.

For a provider the chain does not adapt to yet, prefer an environment
reference over a copied value, so rotation stays the provider's job.

## When there is no key and no agent

That is the first-run case `M-x setup-secrets` exists for. Hosted inference
needs a key, a key needs a provider, and Gemini Nano runs in the browser
with no key at all, so it stays the fallback while the rest is arranged.
