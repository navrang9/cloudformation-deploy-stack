# CloudFormation Deployment Wrapper

This repository contains a reusable shell wrapper for AWS CloudFormation deployments


## Overview

The goal of this setup is to avoid hardcoded deployment values such as:

- CloudFormation template file
- parameter JSON file
- IAM role ARN
- AWS region
- stack name

Instead, all important deployment settings are passed in as parameters, either directly to the shell script, through a configuration file.

The script supports two input methods:

- direct command-line arguments
- a `key=value` configuration file passed with `--config`

Command-line arguments override values loaded from the configuration file.

## Getting Started

1. Download the script into your home directory:

```bash
curl -fsSL https://raw.githubusercontent.com/navrang9/cloudformation-deploy-stack/refs/heads/main/cloudformation-deploy-stack.sh -o ~/cloudformation-deploy-stack.sh
chmod +x ~/cloudformation-deploy-stack.sh
```

2. Add the cds alias to your shell config.

```bash
echo 'alias cds="$HOME/cloudformation-deploy-stack.sh"' >> ~/.zshrc
source ~/.zshrc
```

Now you can run it anywhere just by typing:
`cds`

## Usage

```bash
./cloudformation-deploy-stack.sh \
  [--config <config-file>] \
  [--stack-name <stack-name>] \
  [--template-file <template-file>] \
  [--parameter-file <parameter-file>] \
  [--set-param <key=value>]... \
  [--assume-role-arn <role-arn>] \
  [--cloudformation-role-arn <role-arn>] \
  [--region <aws-region>] \
  [--profile <aws-profile>] \
  [--capabilities <capabilities>] \
  [--tag <key=value>]... \
  [--extra-arg <arg>]... \
  [--dry-run] \
  [--no-assume-role]
````

### Input Modes

The script can be used in two ways:

#### 1. Command-line only

All values are passed directly when calling the script.

Example:

```bash
./cloudformation-deploy-stack.sh \
  --stack-name my-service-staging \
  --template-file cloudformation.yaml \
  --parameter-file params/staging.json \
  --region us-east-1
```

#### 2. Configuration file

Reusable values are stored in a config file and passed using `--config`.

Example:

```bash
./cloudformation-deploy-stack.sh --config deploy-staging.conf
```

#### 3. Configuration file with CLI overrides

Values from the config file can be overridden on the command line.

Example:

```bash
./cloudformation-deploy-stack.sh \
  --config deploy-staging.conf \
  --dry-run \
  --region eu-central-1
```

In this case:

* the config file provides the base values
* `--dry-run` and `--region` override or extend those values for this execution

## Configuration File Format

The configuration file uses plain `key=value` lines.

Supported keys:

```text
environment=<value>
stack_name=<value>
template_file=<value>
parameter_file=<value>
set_param=<key=value>
assume_role_arn=<value>
cloudformation_role_arn=<value>
region=<value>
profile=<value>
capabilities=<value>
dry_run=true|false
no_assume_role=true|false
tag=<key=value>
extra_arg=<arg>
```

Notes:

* Empty lines are ignored.
* Lines starting with `#` are treated as comments.
* `tag` may be specified multiple times.
* `extra_arg` may be specified multiple times.
* `set_param` may be specified multiple times.
* Optional single or double quotes around values are supported.
* The config file is parsed by the script itself and is not executed as shell code.

### Example Configuration File

```ini
# Required values
environment=staging
stack_name=my-stack
template_file=cloudformation.yaml
parameter_file=params/staging.json
set_param=ImageTag=1.2.3
set_param=LogLevel=debug

# Optional values
assume_role_arn=arn:aws:iam::123456789012:role/MyAutomationRole
cloudformation_role_arn=arn:aws:iam::123456789012:role/CloudFormationExecutionRole
region=eu-central-1
profile=default
capabilities=CAPABILITY_NAMED_IAM

# Boolean values
dry_run=false
no_assume_role=false

# Repeatable values
tag=app=my-service
tag=env=staging
tag=owner=platform-team

extra_arg=--debug
```

## Parameters

### `--config`

Optional path to a configuration file in `key=value` format.

Example:

```bash
--config deploy-staging.conf
```

Values loaded from this file can be overridden by command-line arguments.

### `--environment`

Logical environment name, such as `staging` or `prod`.

This value is mainly used for logging and for the temporary STS session name when `--assume-role-arn` is used.

### `--stack-name`

Name of the CloudFormation stack to deploy.

Example:

```bash
--stack-name my-service-staging
```

### `--template-file`

Path to the CloudFormation template file.

Example:

```bash
--template-file cloudformation.yaml
```

### `--parameter-file`

Path to the CloudFormation parameter JSON file.

Example:

```bash
--parameter-file params/staging.json
```

This file is passed to AWS CLI using:

```bash
--parameter-overrides file://<parameter-file>
```

When one or more `--set-param` values are passed, the script creates a temporary merged parameter file first, then passes that generated file to AWS CLI.

Example:

```bash
--set-param ImageTag=1.2.3 --set-param LogLevel=debug
```

If a parameter already exists in the JSON file, its value is replaced. If it does not exist, a new parameter entry is appended.

Supported parameter file formats:

```json
[
  {
    "ParameterKey": "ImageTag",
    "ParameterValue": "1.2.3"
  }
]
```

```json
{
  "Parameters": {
    "ImageTag": "1.2.3"
  }
}
```

In both cases parameter names and values must be strings.

### `--assume-role-arn`

Optional IAM role ARN used for `aws sts assume-role` before deployment.

Use this when the caller must switch identity before running AWS CLI commands.

Example:

```bash
--assume-role-arn arn:aws:iam::123456789012:role/MyAutomationRole
```

### `--cloudformation-role-arn`

Optional IAM role ARN passed to:

```bash
aws cloudformation deploy --role-arn ...
```

This is the CloudFormation execution role, which is different from the STS assume role.

### `--region`

AWS region used for deployment.

Example:

```bash
--region us-east-1
```

### `--profile`

Optional AWS CLI profile.

Use this when you want to run the deployment using a named local AWS profile.

Example:

```bash
--profile my-aws-profile
```

### `--capabilities`

CloudFormation capabilities passed to the deploy command.

Default:

```text
CAPABILITY_NAMED_IAM
```

Common values:

* `CAPABILITY_IAM`
* `CAPABILITY_NAMED_IAM`

### `--tag`

Stack tag in `key=value` format.

This parameter may be used multiple times.

Example:

```bash
--tag app=my-service --tag env=staging
```

When both config file and CLI tags are used, CLI tags are appended to the tags loaded from the config file.

### `--extra-arg`

Additional raw argument passed to `aws cloudformation deploy`.

This parameter may be used multiple times.

Example:

```bash
--extra-arg --disable-rollback
```

When both config file and CLI extra arguments are used, CLI values are appended to the values loaded from the config file.

### `--dry-run`

Creates a change set without executing it.

Internally this adds:

```bash
--no-execute-changeset
```

This may be set either in the config file or on the command line.

### `--no-assume-role`

Skips STS assume-role even if `--assume-role-arn` is provided.

Use this when you want to deploy with the current AWS identity.

This may be set either in the config file or on the command line.

## Examples

### Command-line only

```bash
./cloudformation-deploy-stack.sh \
  --environment staging \
  --stack-name my-service-staging \
  --template-file cloudformation.yaml \
  --parameter-file params/staging.json \
  --assume-role-arn arn:aws:iam::123456789012:role/MyAutomationRole \
  --region us-east-1 \
  --tag app=my-service \
  --tag env=staging
```

### Config file only

```bash
./cloudformation-deploy-stack.sh --config deploy-staging.conf
```

### Config file with overrides

```bash
./cloudformation-deploy-stack.sh \
  --config deploy-prod.conf \
  --dry-run \
  --region us-east-1
```

### Config file with parameter overrides

```bash
./cloudformation-deploy-stack.sh \
  --config deploy-staging.conf \
  --set-param ImageTag=1.2.3 \
  --set-param LogLevel=debug
```

## Notes

* The script does not hardcode environment-specific values.
* The same script can be reused across multiple stacks and environments.
* The script supports both direct CLI usage and reusable config files.


## Files

- `cloudformation-deploy-stack.sh` 
  Generic deployment script for AWS CloudFormation.

- `deploy-<environment>.conf`  
  Optional configuration file in `key=value` format for reusable deployment settings.

## Requirements

- Bash
- AWS CLI v2
- AWS credentials with permission to deploy CloudFormation stacks
- Optional: permission to call `sts assume-role`

No `jq` or Python dependency is required. The configuration file format is plain `key=value`, and `--set-param` merging is handled inside the shell script.
