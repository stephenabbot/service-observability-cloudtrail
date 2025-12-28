# Service Observability CloudTrail

## CloudFormation Foundation for AWS Audit Logging

Creates foundational audit logging infrastructure using CloudFormation for AWS governance, compliance, and security monitoring. Deploys CloudTrail with S3 storage, optional CloudWatch Logs streaming, lifecycle management for cost optimization, and SSM parameter publishing for downstream tool discovery.

Repository: [service-observability-cloudtrail](https://github.com/stephenabbot/service-observability-cloudtrail)

## What Problem This Project Solves

AWS accounts generate thousands of API calls daily from users, applications, and automated processes. Without audit logging, determining who made changes, when they occurred, and what was affected becomes impossible.

- Security incidents cannot be investigated without comprehensive API activity logs
- Compliance requirements cannot be met without proper audit trail documentation
- Operational troubleshooting lacks critical context about infrastructure changes
- Manual CloudTrail configuration creates inconsistency across accounts and risks misconfiguration
- Complex interactions between CloudTrail, S3, IAM, and CloudWatch Logs require specialized knowledge

## What This Project Does

Provides foundational audit logging by deploying CloudTrail with comprehensive storage and monitoring capabilities. Uses CloudFormation for consistent deployment and publishes resource identifiers for service discovery.

- Deploys CloudTrail with S3 storage for durable audit log retention
- Configures optional CloudWatch Logs streaming for real-time event querying and alerting
- Implements S3 lifecycle management with Intelligent Tiering and Glacier transitions for cost optimization
- Publishes trail resource identifiers to SSM Parameter Store for consuming project discovery
- Supports both single-region and multi-region trails through configuration options
- Provides script-based deployment with prerequisite validation and idempotent operations
- Enables selective deployment for cost management during development or continuous deployment for compliance

## What This Project Changes

Creates foundational audit logging infrastructure using CloudFormation with comprehensive resource tagging and service discovery integration.

### Resources Created

- CloudTrail trail with configurable event capture for management and optional data events
- S3 bucket for audit log storage with versioning, encryption, and intelligent tiering
- S3 bucket policy allowing CloudTrail service access while blocking unauthorized access
- CloudWatch Logs log group for real-time event streaming when integration enabled
- IAM role for CloudTrail CloudWatch Logs delivery when integration enabled
- SSM parameters publishing trail name, S3 bucket, and CloudWatch Logs resource identifiers
- CloudFormation stack managing all resources with consistent tagging and dependency management

### Functional Changes

- Enables comprehensive AWS API activity logging for security analysis and compliance reporting
- Provides real-time event streaming to CloudWatch Logs for immediate alerting and analysis
- Establishes automated cost optimization through S3 lifecycle policies and intelligent tiering
- Creates service discovery mechanism for consuming projects to find audit logging resources
- Implements configurable event capture supporting both cost-optimized and compliance-focused deployments

## Quick Start

Basic deployment workflow:

```bash
# Clone repository and configure environment
git clone https://github.com/stephenabbot/service-observability-cloudtrail.git
cd service-observability-cloudtrail

# Configure deployment settings
cp .env.example .env
# Edit .env with your AWS region, tags, and CloudTrail configuration

# Verify prerequisites and deploy
./scripts/verify-prerequisites.sh
./scripts/deploy.sh

# Verify deployment
./scripts/list-deployed-resources.sh
```

See [prerequisites documentation](docs/prerequisites.md) for detailed requirements, [troubleshooting guide](docs/troubleshooting.md) for common issues, [configuration documentation](docs/configuration.md) for detailed parameter reference, and [cost estimation guide](docs/cost-estimation.md) for deployment cost analysis.

## AWS Well-Architected Framework

This project demonstrates alignment with the [AWS Well-Architected Framework](https://aws.amazon.com/blogs/apn/the-6-pillars-of-the-aws-well-architected-framework/):

### Security

- CloudTrail audit logging captures all API activity for security analysis and incident investigation
- S3 bucket encryption with server-side encryption protects audit logs at rest
- IAM roles with least privilege principles for CloudWatch Logs delivery
- S3 bucket policies restrict access to CloudTrail service while blocking unauthorized access

### Operational Excellence

- CloudFormation infrastructure as code with automated deployment and rollback capabilities
- Comprehensive deployment scripts with prerequisite validation and error handling
- Resource listing capabilities enable infrastructure visibility and configuration drift detection
- SSM Parameter Store integration provides service discovery for consuming projects

### Reliability

- Multi-region CloudTrail support captures events across all AWS regions automatically
- S3 versioning and cross-region replication capabilities for audit log durability
- Idempotent deployment operations support multiple execution attempts without conflicts
- CloudFormation stack management with automatic rollback on deployment failures

### Cost Optimization

- S3 Intelligent Tiering automatically optimizes storage costs based on access patterns
- Configurable lifecycle policies transition older logs to Glacier for long-term cost reduction
- Selective event capture options balance audit coverage against logging costs
- CloudWatch Logs retention policies prevent indefinite log accumulation costs

## Technologies Used

| Technology | Purpose | Implementation |
|------------|---------|----------------|
| Kiro CLI with Claude | AI-assisted development, design, and implementation | Project architecture design and infrastructure code generation |
| AWS CloudFormation | Infrastructure as code and stack management | Declarative infrastructure deployment with drift detection and automated rollback |
| AWS CloudTrail | API activity logging and audit trail creation | Multi-region trail configuration with management and optional data event capture |
| AWS S3 | Durable audit log storage | Versioned buckets with server-side encryption, intelligent tiering, and lifecycle policies |
| AWS CloudWatch Logs | Real-time event streaming and querying | Optional log group integration with configurable retention periods |
| AWS IAM | Access control and service trust policies | Least privilege roles for CloudWatch Logs delivery with CloudTrail trust relationships |
| AWS SSM Parameter Store | Resource identifier publishing and service discovery | Predictable parameter paths for consuming project integration |
| Bash | Deployment automation and operational workflows | Scripts for prerequisite validation, deployment orchestration, and resource management |
| AWS CLI | Service interaction and credential management | CloudFormation operations, resource verification, and AWS service integration |
| Git | Version control and repository metadata detection | Automated resource naming and tagging from repository information |
| jq | JSON processing and configuration handling | Parameter parsing, output processing, and deployment script data manipulation |

## Copyright

© 2025 Stephen Abbot - MIT License
