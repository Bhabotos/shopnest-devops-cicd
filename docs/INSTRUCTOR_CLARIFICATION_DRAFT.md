# Draft: questions for the instructor (NOT SENT)

Status: draft prepared 2026-11-21 for the project owner to review and send. It has not been sent and no reply exists. Decisions D1 and D2 in
`docs/PROJECT_EXECUTION_ROADMAP.md` stay "waiting for instructor confirmation" until a real reply is recorded in `PROJECT_STATUS.md`.

---

Subject: ShopNest GitHub Actions assignment: two clarification questions

Dear [Instructor],

I am working on the ShopNest GitHub Actions assignment and would like to confirm two points before I finish the AWS deployment part.

1. **Deployment method (Part E).** The assignment asks for an automated deployment to the EC2 server "over SSH". My design keeps port 22 closed and deploys through
   AWS Systems Manager (Session Manager / Run Command) with short-lived GitHub OIDC credentials, so no SSH key or open SSH port exists. Does this satisfy the requirement to deploy over SSH,
   or must the pipeline itself use an SSH connection?

2. **Topology.** I plan a staging environment with one EC2 instance and a production environment with two EC2 instances behind a load balancer, with a private database. Is this the topology you expect,
   or do you expect a different layout (for example a single EC2 instance for everything)?

(Optional, related to Part D and the submission rules.) The assignment forbids any server address in the repository but also asks for the live URL in the README. May I give the URL only in the submission
form rather than in the repository, or is a DNS name in the README acceptable?

Thank you,
[Student name]
