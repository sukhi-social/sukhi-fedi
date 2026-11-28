# SPDX-License-Identifier: AGPL-3.0-or-later
# `HOSI_REAL=1` runs on libhosi and Datalevin (`HOSI_JAR`, `HOSI_JAVA`); otherwise on the
# in-memory stand-in.
ExUnit.start(exclude: if(System.get_env("HOSI_REAL"), do: [], else: [:real]))
