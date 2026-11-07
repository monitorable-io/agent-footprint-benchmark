# Linux monitoring agent footprint benchmark (2026): 11 agents, one VPS type, 24 hours

| Agent | Version | Memory (PSS), idle median | Memory peak (cgroup), whole cycle | CPU, idle (% of one vCPU) | CPU, under load (% of one vCPU) | Disk written per 24 h | Network per 24 h (out for push agents, in+out for polled) | Install wall time | On-disk footprint after the cycle |
|---|---|---|---|---|---|---|---|---|---|
| HetrixTools agent | 2.4.2 | 0.0 | 14.4 | 16.9 | 12.3 | 5.9 | 3.8 | 2.1 | 0.1 |
| Beszel agent | beszel-agent 0.21.1 | 17.9 | 117.4 | 0.1 | 0.1 | 0.0 | 3.8 | 3.5 | 10.8 |
| node_exporter | v1.12.1 | 24.5 | 10.5 | 0.0 | 0.0 | 0.0 | 19.7 | 1.9 | 23.9 |
| Monitorable agent (us) | monitorable-agent version v1.5.0 | 45.9 | 19.3 | 0.1 | 0.1 | 115.5 | 8.2 | 6.6 | 57.4 |
| Fivenines agent | fivenines-agent 1.22.0 | 49.6 | 127.7 | 0.2 | 0.1 | 0.4 | 10.1 | 5.2 | 51.3 |
| Pulse agent | v6.6.0 | 49.6 | 33.8 | 0.1 | 0.0 | 11.8 | 16.2 | 31.4 | 42.1 |
| Glances | 4.5.8 | 88.9 | 75.8 | 2.3 | 1.5 | 0.0 | 3964.5 | 34.6 | 48.7 |
| Telegraf | Telegraf 1.40.3 (git: HEAD@41b45388) | 181.2 | 59.1 | 0.2 | 0.2 | 0.0 | 17.3 | 8.4 | 328.4 |
| Datadog Agent | Agent 7.85.0 | 193.4 | 199.0 | 1.5 | 1.1 | 103.3 | 90.4 | 18.4 | 1619.3 |
| Netdata (claimed to Netdata Cloud) | v2.12.2 | 350.6 | 285.7 | 3.8 | 2.8 | 516.5 | 49.1 | 27.2 | 793.9 |
| Netdata (self-hosted) | v2.12.2 | 350.7 | 271.7 | 3.8 | 3.0 | 460.3 | 48.5 | 23.0 | 789.2 |
| No agent (harness only) | none | 11.5 | 27.5 | 0.1 | 0.1 | 10.4 | 0.0 | 0.0 | 0.1 |

Cycles: 3. Hetzner Cloud Helsinki (HEL1) CX23: 2 vCPU AMD EPYC (shared), 4 GB RAM, 40 GB NVMe, Ubuntu 26.04 LTS, kernel 7.0.0-15 to 7.0.0-42-generic (the stock image's kernel moved between rebuilds; each cycle's meta.json records its own), harness c7f668b.
