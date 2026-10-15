// SPDX-License-Identifier: AGPL-3.0-or-later
//
// What /licenses lists that no lockfile does: the runtime images, the native
// code inside NIFs, build and CI tools, the fonts and pictures. Written by
// hand — a person decides what we run — but the license and the LICENSE file
// link are asked of GitHub (`gh api repos/<repo>/license`), not remembered.
//
// `repo` is where the project lives on GitHub; `href` is the page the name
// leads to (the repo, unless the project has a better front door).
// `license` is only given where GitHub answers NOASSERTION or has no repo to
// ask: each was checked against the project's own license text.
//
// `cat` is a category id from gen_licenses.mjs. `requires: 'ojak'` lists the
// entry only while ojak is in the dependency tree (see gen_licenses.mjs).

export const extra = [
  // Languages
  { cat: 'languages', name: 'Erlang/OTP', version: '28.4', repo: 'erlang/otp', website: 'https://www.erlang.org/' },
  { cat: 'languages', name: 'Elixir', version: '1.20', repo: 'elixir-lang/elixir', website: 'https://elixir-lang.org/' },
  // Rust builds ojak's NIF (the Rust crates on /licenses/rust); listed with ojak.
  {
    cat: 'languages',
    name: 'Rust',
    repo: 'rust-lang/rust',
    website: 'https://www.rust-lang.org/',
    license: 'MIT OR Apache-2.0',
    licenseHref: 'https://github.com/rust-lang/rust/blob/HEAD/LICENSE-MIT',
    notice: '© The Rust Project Contributors',
    requires: 'ojak',
  },
  { cat: 'languages', name: 'Node.js', version: '24', repo: 'nodejs/node', website: 'https://nodejs.org/', license: 'MIT' },

  // Federation — Feder is where ojak began (ojak started as a fork of it, as its
  // author tells; it has grown far past that). We do not link its code, but
  // it is a source of the design we stand on.
  { cat: 'federation', name: 'Feder', repo: 'fedify-dev/feder', notice: 'by fedify-dev', requires: 'ojak' },

  // Data & messaging
  {
    cat: 'data-messaging',
    name: 'PostgreSQL',
    version: '16',
    repo: 'postgres/postgres',
    website: 'https://www.postgresql.org/',
    license: 'PostgreSQL',
    licenseHref: 'https://www.postgresql.org/about/licence/',
  },
  { cat: 'data-messaging', name: 'NATS', version: '2', repo: 'nats-io/nats-server', website: 'https://nats.io/' },
  { cat: 'data-messaging', name: 'rustfs', version: '1.0.0-beta.5', repo: 'rustfs/rustfs', website: 'https://rustfs.com/' },

  // Security
  { cat: 'security', name: 'Anubis', version: '1.27.0', repo: 'TecharoHQ/anubis', website: 'https://anubis.techaro.lol/' },
  {
    cat: 'security',
    name: 'Argon2 (reference C implementation)',
    repo: 'P-H-C/phc-winner-argon2',
    license: 'CC0-1.0 OR Apache-2.0',
  },

  // Frontend & media
  { cat: 'frontend-media', name: 'libvips', repo: 'libvips/libvips', website: 'https://www.libvips.org/' },
  {
    cat: 'frontend-media',
    name: 'Twemoji (graphics)',
    repo: 'jdecked/twemoji',
    license: 'CC-BY-4.0',
    licenseHref: 'https://creativecommons.org/licenses/by/4.0/',
    notice: '© 2022–present Jason Sofonia & Justine De Caires; © 2014–2021 Twitter',
  },
  {
    cat: 'frontend-media',
    name: 'IBM Plex Sans',
    repo: 'IBM/plex',
    website: 'https://www.ibm.com/plex/',
  },
  {
    cat: 'frontend-media',
    name: 'BIZ UDPGothic',
    repo: 'googlefonts/morisawa-biz-ud-gothic',
    notice: '© 2022 The BIZ UDGothic Project Authors',
  },
  {
    cat: 'frontend-media',
    name: 'Nanum Gothic',
    href: 'https://hangeul.naver.com/font/nanum',
    license: 'OFL-1.1',
    licenseHref: 'https://openfontlicense.org/open-font-license-official-text/',
    notice: '© 2010 NHN Corporation',
  },

  // Tools
  { cat: 'tools', name: 'mise', repo: 'jdx/mise', website: 'https://mise.jdx.dev/' },
  { cat: 'infrastructure', name: 'pnpm/action-setup', version: 'v4', repo: 'pnpm/action-setup' },

  // Infrastructure
  { cat: 'infrastructure', name: 'Alpine Linux', href: 'https://alpinelinux.org/', license: 'various' },
  { cat: 'infrastructure', name: 'Docker (Moby)', repo: 'moby/moby', website: 'https://www.docker.com/' },
  { cat: 'infrastructure', name: 'cloudflared', repo: 'cloudflare/cloudflared' },
  { cat: 'infrastructure', name: 'Watchtower', repo: 'containrrr/watchtower' },
  { cat: 'infrastructure', name: 'Haloy', repo: 'haloydev/haloy' },
  {
    cat: 'infrastructure',
    name: 'Terraform',
    repo: 'hashicorp/terraform',
    license: 'BUSL-1.1',
    licenseHref: 'https://github.com/hashicorp/terraform/blob/HEAD/LICENSE',
    notice: '© IBM Corp. (1.6 and later)',
  },
  { cat: 'infrastructure', name: 'Terraform provider for OCI', repo: 'oracle/terraform-provider-oci' },
  { cat: 'infrastructure', name: 'actions/checkout', version: 'v4', repo: 'actions/checkout' },
  { cat: 'infrastructure', name: 'actions/setup-node', version: 'v4', repo: 'actions/setup-node' },
  { cat: 'infrastructure', name: 'actions/upload-artifact', version: 'v4', repo: 'actions/upload-artifact' },
  { cat: 'infrastructure', name: 'actions/download-artifact', version: 'v4', repo: 'actions/download-artifact' },
  { cat: 'infrastructure', name: 'docker/build-push-action', version: 'v5', repo: 'docker/build-push-action' },
  { cat: 'infrastructure', name: 'docker/login-action', version: 'v3', repo: 'docker/login-action' },
  { cat: 'infrastructure', name: 'docker/metadata-action', version: 'v5', repo: 'docker/metadata-action' },
  { cat: 'infrastructure', name: 'docker/setup-buildx-action', version: 'v3.10.0', repo: 'docker/setup-buildx-action' },
];
