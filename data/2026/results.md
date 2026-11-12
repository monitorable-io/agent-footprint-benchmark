# Linux monitoring agent footprint benchmark (2026): 11 agents, one VPS type, 24 hours

| Agent | Version | Memory (PSS), idle median | Memory peak (cgroup), whole cycle | CPU, idle (% of one vCPU) | CPU, under load (% of one vCPU) | Disk written per 24 h | Network per 24 h (out for push agents, in+out for polled) | Install wall time | On-disk footprint after the cycle |
|---|---|---|---|---|---|---|---|---|---|
| HetrixTools agent | 2.4.2 | 9.0 | 12.5 | 17.0 | 12.9 | 5.9 | 3.8 | 2.1 | 0.1 |
| Beszel agent | beszel-agent 0.21.1 | 17.9 | 118.1 | 0.2 | 0.2 | 0.0 | 3.8 | 3.6 | 10.8 |
| node_exporter | v1.12.1 | 24.5 | 10.6 | 0.0 | 0.0 | 0.0 | 19.7 | 1.8 | 23.9 |
| Monitorable agent (us) | monitorable-agent version v1.7.0 | 45.5 | 18.6 | 0.1 | 0.1 | 0.3 | 8.1 | 6.4 | 57.3 |
| Pulse agent | v6.6.0 | 49.5 | 17.3 | 0.1 | 0.0 | 11.8 | 16.2 | 31.3 | 42.1 |
| Fivenines agent | fivenines-agent 1.23.1 | 49.9 | 128.7 | 0.2 | 0.2 | 0.5 | 10.0 | 4.1 | 52.1 |
| Glances | 4.5.9 | 77.7 | 72.6 | 2.4 | 1.7 | 0.0 | 3929.7 | 33.4 | 28.8 |
| Telegraf | Telegraf 1.40.3 (git: HEAD@41b45388) | 180.2 | 59.0 | 0.2 | 0.2 | 0.0 | 17.3 | 7.9 | 330.6 |
| Datadog Agent | Agent 7.85.3 | 195.7 | 198.6 | 1.6 | 1.1 | 103.2 | 89.3 | 17.9 | 1619.3 |
| Netdata (self-hosted) | v2.12.3 | 354.7 | 294.4 | 3.8 | 2.9 | 265.9 | 0.0 | 21.2 | 790.7 |
| Netdata (claimed to Netdata Cloud) | v2.12.3 | 356.4 | 295.6 | 3.7 | 2.8 | 259.6 | 0.3 | 25.4 | 794.7 |
| No agent (harness only) | none | 12.6 | 16.1 | 0.1 | 0.1 | 10.5 | 0.0 | n/a | 0.1 |

Cycles: 3. Hetzner Cloud Helsinki (HEL1) CX23: 2 vCPU AMD EPYC (shared), 4 GB RAM, 40 GB NVMe, Ubuntu 26.04 LTS, kernel 7.0.0-15/-30/-42/-43-generic (differs by box, see kernels), harness d879a73.
