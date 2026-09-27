---
name: israel-2026-payroll
summary: Israel 2026 payroll constants + Netanel's terms, validated to the shekel against his Aug-2026 payslip
pinned: true
created: 2026-09-16
modified: 2026-09-16
---
Monthly brackets 2026: 10% to 7,010 | 14% to 10,060 | 20% to 19,000 | 31% to 25,100 | 35% to 46,690 | 47% to 60,130 | 50% above (47%+3% surtax). Slices only, not the whole sum. Credit point 242/mo (2,904/yr).
Bituach leumi+health employee: 4.27% to 7,703, 12.17% to 51,910, 0 above.
Nahariya is a preferred settlement (official list 14.1.2026): score 52, 12% credit on earned income up to 226,560/yr = 2,266/mo, needs centre of life there.
Keren hishtalmut: employer exempt up to 7.5% of salary, salary ceiling 15,712/mo (188,544/yr); above it the employer's deposit is taxed and nipped for b.l. like salary (his slip: "שווי קרן השתלמות" 1,372).
Zikui gemel (pension credit, sec 45a): 35% of the employee deposit, capped at ~237/mo for 2026.
His terms (שיא קרופ, Nahariya): 34,000 gross, 9.25 points, pension 6% him / 6.5% tagmulim + 8.33% pitzuim employer, keren 2.5% him / 7.5% employer with no cap.
His Aug-2026 slip: 27,200 base + 6,800 overtime + 293 travel = 34,293; taxable 35,665; tax 3,763; b.l. 2,038 + health 1,694; pension 2,040; keren 850; net 23,908. Board reproduces every line. Model: ~/.config/assistant/boards/salary-net.qml

Verified against that slip (pdf ~/Downloads/תלוש לבן.PDF, שיא קרופ בע"מ) to the shekel: taxable base = 34,293 + 1,372 shovi keren = 35,665; tax 3,763 (after 2,238 personal + 2,266 Nahariya + 237 gemel credits); employee BL 2,038 + health 1,694 (1.04/7% and 3.23/5.17 on 35,665); net 23,908. Pension/keren/pitzuim on BOTH sides are 6/2.5/6.5/7.5/8.33% of the 34,000 BASE salary, overtime excluded (2,040 = 6% of 34,000, not of 34,293); cumulative columns confirm (pitzuim 22,656 = 2,832x8, keren 20,400 = 2,550x8, kopag 17,680 = 2,210x8).

Employer cost, the number he asks about: the slip prints employer pension 2,210 + keren 2,550 + pitzuim 2,832 but NEVER the employer's bituach leumi, so the slip's visible employer cost is 41,885 ("the 42") while the true cost is 44,358 for Aug and 44,042 for a base-only 34k month. Employer BL is inferred from the 2026 BTL table (4.51% to 7,703, 7.6% to 51,910; health has no employer share) on the slip's own BL base 35,665 = 2,473. That inference is the only unprinted piece.
