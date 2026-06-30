#!/usr/bin/env bash
set -euo pipefail

declare -a temp_files=()
declare -a parsed_parameter_keys=()
declare -a parsed_parameter_values=()
declare -a output_parameter_keys=()
declare -a output_parameter_values=()
parsed_parameter_format=""

usage() {
  cat >&2 <<'EOF'
Usage:
  deploy_stack.sh \
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

Description:
  Generic CloudFormation deploy wrapper.

Notes:
  --config points to a key=value configuration file.
  Command line arguments override values from the config file.
  --set-param overrides or adds values in the parameter JSON before deploy.
  --assume-role-arn is used for STS assume-role before running AWS CLI commands.
  --cloudformation-role-arn is passed to 'aws cloudformation deploy --role-arn'.
  These are different roles and may be used independently.

Supported config keys:
  stack_name=<value>
  template_file=<value>
  parameter_file=<value>
  set_param=<key=value>      # repeatable
  assume_role_arn=<value>
  cloudformation_role_arn=<value>
  region=<value>
  profile=<value>
  capabilities=<value>
  dry_run=true|false
  no_assume_role=true|false
  tag=<key=value>          # repeatable
  extra_arg=<arg>          # repeatable

Examples:
  deploy_stack.sh \
    --stack-name my-stack \
    --template-file cloudformation.yaml \
    --parameter-file params/staging.json \
    --assume-role-arn arn:aws:iam::123456789012:role/DeploymentAutomation \
    --region us-east-1 \
    --tag app=my-service \
    --tag env=staging

  deploy_stack.sh \
    --config deploy-staging.conf

  deploy_stack.sh \
    --config deploy-prod.conf \
    --dry-run
EOF
}

log() {
  echo "[INFO] $*"
}

error() {
  echo "[ERROR] $*" >&2
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    error "Required command not found: $cmd"
    exit 1
  }
}

cleanup_temp_files() {
  local path=""

  for path in "${temp_files[@]}"; do
    [[ -n "$path" && -f "$path" ]] && rm -f "$path"
  done
}

trap cleanup_temp_files EXIT

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || {
    error "File not found: $path"
    exit 1
  }
}

trim() {
  local s="$1"

  # Remove leading whitespace
  s="${s#"${s%%[![:space:]]*}"}"
  # Remove trailing whitespace
  s="${s%"${s##*[![:space:]]}"}"

  printf '%s' "$s"
}

strip_optional_quotes() {
  local s="$1"

  if [[ ${#s} -ge 2 ]]; then
    if [[ "${s:0:1}" == '"' && "${s: -1}" == '"' ]]; then
      s="${s:1:${#s}-2}"
    elif [[ "${s:0:1}" == "'" && "${s: -1}" == "'" ]]; then
      s="${s:1:${#s}-2}"
    fi
  fi

  printf '%s' "$s"
}

parse_bool() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    true|1|yes|y|on)
      printf 'true'
      ;;
    false|0|no|n|off)
      printf 'false'
      ;;
    *)
      error "Invalid boolean value: $1"
      exit 1
      ;;
  esac
}

validate_parameter_override() {
  local override="$1"

  [[ "$override" == *"="* ]] || {
    error "Invalid --set-param value '$override'. Expected key=value."
    exit 1
  }

  [[ -n "${override%%=*}" ]] || {
    error "Invalid --set-param value '$override'. Key cannot be empty."
    exit 1
  }
}

json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\b'/\\b}"

  printf '%s' "$value"
}

extract_json_string_field_raw() {
  local json="$1"
  local field_name="$2"
  local search="\"${field_name}\""
  local remainder=""
  local result=""
  local char=""
  local escaped=false
  local idx=0

  remainder="${json#*${search}}"
  [[ "$remainder" != "$json" ]] || return 1

  remainder="${remainder#*:}"
  [[ "$remainder" != "${json#*${search}}" ]] || return 1

  remainder="${remainder#"${remainder%%[![:space:]]*}"}"
  [[ "${remainder:0:1}" == '"' ]] || return 1
  remainder="${remainder:1}"

  for ((idx = 0; idx < ${#remainder}; idx++)); do
    char="${remainder:idx:1}"

    if [[ "$escaped" == true ]]; then
      result+="$char"
      escaped=false
      continue
    fi

    case "$char" in
      \\)
        result+="$char"
        escaped=true
        ;;
      \")
        printf '%s' "$result"
        return 0
        ;;
      *)
        result+="$char"
        ;;
    esac
  done

  return 1
}

find_override_index() {
  local key="$1"
  shift

  local -a override_keys=("$@")
  local idx=0

  for ((idx = 0; idx < ${#override_keys[@]}; idx++)); do
    if [[ "${override_keys[idx]}" == "$key" ]]; then
      printf '%s' "$idx"
      return 0
    fi
  done

  return 1
}

extract_json_object_field_raw() {
  local json="$1"
  local field_name="$2"
  local search="\"${field_name}\""
  local remainder=""
  local result=""
  local char=""
  local idx=0
  local depth=0
  local in_string=false
  local escaped=false

  remainder="${json#*${search}}"
  [[ "$remainder" != "$json" ]] || return 1

  remainder="${remainder#*:}"
  [[ "$remainder" != "${json#*${search}}" ]] || return 1

  remainder="${remainder#"${remainder%%[![:space:]]*}"}"
  [[ "${remainder:0:1}" == "{" ]] || return 1

  for ((idx = 0; idx < ${#remainder}; idx++)); do
    char="${remainder:idx:1}"
    result+="$char"

    if [[ "$in_string" == true ]]; then
      if [[ "$escaped" == true ]]; then
        escaped=false
      elif [[ "$char" == "\\" ]]; then
        escaped=true
      elif [[ "$char" == '"' ]]; then
        in_string=false
      fi
      continue
    fi

    case "$char" in
      \")
        in_string=true
        ;;
      "{")
        depth=$((depth + 1))
        ;;
      "}")
        depth=$((depth - 1))
        if [[ "$depth" -eq 0 ]]; then
          printf '%s' "$result"
          return 0
        fi
        ;;
    esac
  done

  return 1
}

parse_parameter_array_file() {
  local json_content="$1"

  parsed_parameter_format="array"
  parsed_parameter_keys=()
  parsed_parameter_values=()

  local current_object=""
  local char=""
  local key_raw=""
  local value_raw=""
  local depth=0
  local idx=0
  local object_count=0
  local in_string=false
  local escaped=false

  for ((idx = 0; idx < ${#json_content}; idx++)); do
    char="${json_content:idx:1}"

    if [[ "$depth" -gt 0 ]]; then
      current_object+="$char"
    fi

    if [[ "$in_string" == true ]]; then
      if [[ "$escaped" == true ]]; then
        escaped=false
      elif [[ "$char" == "\\" ]]; then
        escaped=true
      elif [[ "$char" == '"' ]]; then
        in_string=false
      fi
      continue
    fi

    case "$char" in
      \")
        in_string=true
        ;;
      "{")
        if [[ "$depth" -eq 0 ]]; then
          current_object="{"
        fi
        depth=$((depth + 1))
        ;;
      "}")
        depth=$((depth - 1))
        if [[ "$depth" -eq 0 ]]; then
          key_raw="$(extract_json_string_field_raw "$current_object" "ParameterKey")" || {
            error "Invalid parameter file: each entry must contain a string ParameterKey"
            exit 1
          }
          value_raw="$(extract_json_string_field_raw "$current_object" "ParameterValue")" || {
            error "Invalid parameter file: each entry must contain a string ParameterValue"
            exit 1
          }
          parsed_parameter_keys+=("$key_raw")
          parsed_parameter_values+=("$value_raw")
          object_count=$((object_count + 1))
          current_object=""
        elif [[ "$depth" -lt 0 ]]; then
          error "Invalid parameter file: malformed JSON object structure"
          exit 1
        fi
        ;;
    esac
  done

  if [[ "$depth" -ne 0 || "$in_string" == true ]]; then
    error "Invalid parameter file: malformed JSON content"
    exit 1
  fi

  [[ "$object_count" -gt 0 ]] || {
    error "Invalid parameter file: expected a JSON array of parameter objects"
    exit 1
  }
}

parse_parameter_object_file() {
  local json_content="$1"
  local params_object=""

  params_object="$(extract_json_object_field_raw "$json_content" "Parameters")" || {
    error "Invalid parameter file: expected a top-level Parameters object"
    exit 1
  }

  parsed_parameter_format="object"
  parsed_parameter_keys=()
  parsed_parameter_values=()

  local idx=0
  local len=${#params_object}
  local char=""
  local key_raw=""
  local value_raw=""
  local in_string=false
  local escaped=false

  idx=1
  while [[ "$idx" -lt "$len" ]]; do
    while [[ "$idx" -lt "$len" ]]; do
      char="${params_object:idx:1}"
      [[ "$char" =~ [[:space:]] ]] || break
      idx=$((idx + 1))
    done

    [[ "$idx" -lt "$len" ]] || break
    char="${params_object:idx:1}"

    if [[ "$char" == "}" ]]; then
      break
    fi

    [[ "$char" == '"' ]] || {
      error "Invalid parameter file: Parameters object must contain string keys"
      exit 1
    }

    idx=$((idx + 1))
    key_raw=""
    in_string=true
    escaped=false
    while [[ "$idx" -lt "$len" && "$in_string" == true ]]; do
      char="${params_object:idx:1}"
      if [[ "$escaped" == true ]]; then
        key_raw+="$char"
        escaped=false
      elif [[ "$char" == "\\" ]]; then
        key_raw+="$char"
        escaped=true
      elif [[ "$char" == '"' ]]; then
        in_string=false
      else
        key_raw+="$char"
      fi
      idx=$((idx + 1))
    done
    [[ "$in_string" == false ]] || {
      error "Invalid parameter file: malformed Parameters object key"
      exit 1
    }

    while [[ "$idx" -lt "$len" ]]; do
      char="${params_object:idx:1}"
      [[ "$char" =~ [[:space:]] ]] || break
      idx=$((idx + 1))
    done

    [[ "${params_object:idx:1}" == ":" ]] || {
      error "Invalid parameter file: malformed Parameters object entry"
      exit 1
    }
    idx=$((idx + 1))

    while [[ "$idx" -lt "$len" ]]; do
      char="${params_object:idx:1}"
      [[ "$char" =~ [[:space:]] ]] || break
      idx=$((idx + 1))
    done

    [[ "${params_object:idx:1}" == '"' ]] || {
      error "Invalid parameter file: Parameters object values must be strings"
      exit 1
    }

    idx=$((idx + 1))
    value_raw=""
    in_string=true
    escaped=false
    while [[ "$idx" -lt "$len" && "$in_string" == true ]]; do
      char="${params_object:idx:1}"
      if [[ "$escaped" == true ]]; then
        value_raw+="$char"
        escaped=false
      elif [[ "$char" == "\\" ]]; then
        value_raw+="$char"
        escaped=true
      elif [[ "$char" == '"' ]]; then
        in_string=false
      else
        value_raw+="$char"
      fi
      idx=$((idx + 1))
    done
    [[ "$in_string" == false ]] || {
      error "Invalid parameter file: malformed Parameters object value"
      exit 1
    }

    parsed_parameter_keys+=("$key_raw")
    parsed_parameter_values+=("$value_raw")

    while [[ "$idx" -lt "$len" ]]; do
      char="${params_object:idx:1}"
      [[ "$char" =~ [[:space:]] ]] || break
      idx=$((idx + 1))
    done

    if [[ "${params_object:idx:1}" == "," ]]; then
      idx=$((idx + 1))
      continue
    fi

    if [[ "${params_object:idx:1}" == "}" ]]; then
      break
    fi

    error "Invalid parameter file: malformed Parameters object separator"
    exit 1
  done
}

write_parameter_file() {
  local target_file="$1"
  shift

  local format="$1"
  local idx=0

  if [[ "$format" == "array" ]]; then
    {
      printf '[\n'
      for ((idx = 0; idx < ${#output_parameter_keys[@]}; idx++)); do
        [[ "$idx" -gt 0 ]] && printf ',\n'
        printf '  {\n'
        printf '    "ParameterKey": "%s",\n' "$(json_escape "${output_parameter_keys[idx]}")"
        printf '    "ParameterValue": "%s"\n' "$(json_escape "${output_parameter_values[idx]}")"
        printf '  }'
      done
      printf '\n]\n'
    } > "$target_file"
    return 0
  fi

  if [[ "$format" == "object" ]]; then
    {
      printf '{\n'
      printf '  "Parameters": {\n'
      for ((idx = 0; idx < ${#output_parameter_keys[@]}; idx++)); do
        [[ "$idx" -gt 0 ]] && printf ',\n'
        printf '    "%s": "%s"' "$(json_escape "${output_parameter_keys[idx]}")" "$(json_escape "${output_parameter_values[idx]}")"
      done
      printf '\n  }\n'
      printf '}\n'
    } > "$target_file"
    return 0
  fi

  error "Unsupported parameter file format: $format"
  exit 1
}

build_effective_parameter_file() {
  local source_file="$1"
  shift

  local -a overrides=("$@")
  local override=""

  # Nothing to build: no source file and no overrides.
  if [[ -z "$source_file" && "${#overrides[@]}" -eq 0 ]]; then
    return 0
  fi

  # Source file with no overrides: use it as-is.
  if [[ "${#overrides[@]}" -eq 0 ]]; then
    printf '%s' "$source_file"
    return 0
  fi

  for override in "${overrides[@]}"; do
    validate_parameter_override "$override"
  done

  local temp_dir=""
  temp_dir="${TMPDIR:-/tmp}"
  temp_dir="${temp_dir%/}"

  local temp_file=""
  temp_file="$(mktemp "${temp_dir}/cloudformation-params.XXXXXX")"
  temp_files+=("$temp_file")

  local -a override_keys=()
  local -a override_values=()
  local -a override_used=()
  local override_key=""
  local override_value=""
  local json_content=""
  local trimmed_json=""
  local -a merged_parameter_keys=()
  local -a merged_parameter_values=()
  local existing_idx=0
  local override_idx=""
  local idx=0

  for override in "${overrides[@]}"; do
    override_key="${override%%=*}"
    override_value="${override#*=}"
    override_keys+=("$override_key")
    override_values+=("$override_value")
    override_used+=("false")
  done

  if [[ -n "$source_file" ]]; then
    json_content="$(<"$source_file")"
    trimmed_json="$(trim "$json_content")"

    if [[ "${trimmed_json:0:1}" == "[" ]]; then
      parse_parameter_array_file "$json_content"
    elif [[ "${trimmed_json:0:1}" == "{" ]]; then
      parse_parameter_object_file "$json_content"
    else
      error "Invalid parameter file: expected JSON object or array"
      exit 1
    fi
  else
    # No source file: start from an empty set and emit the array format.
    parsed_parameter_format="array"
    parsed_parameter_keys=()
    parsed_parameter_values=()
  fi

  for ((existing_idx = 0; existing_idx < ${#parsed_parameter_keys[@]}; existing_idx++)); do
    if override_idx="$(find_override_index "${parsed_parameter_keys[existing_idx]}" "${override_keys[@]}")"; then
      override_used[override_idx]="true"
      merged_parameter_keys+=("${override_keys[override_idx]}")
      merged_parameter_values+=("${override_values[override_idx]}")
    else
      merged_parameter_keys+=("${parsed_parameter_keys[existing_idx]}")
      merged_parameter_values+=("${parsed_parameter_values[existing_idx]}")
    fi
  done

  for ((idx = 0; idx < ${#override_keys[@]}; idx++)); do
    if [[ "${override_used[idx]}" == "true" ]]; then
      continue
    fi
    merged_parameter_keys+=("${override_keys[idx]}")
    merged_parameter_values+=("${override_values[idx]}")
  done

  output_parameter_keys=("${merged_parameter_keys[@]}")
  output_parameter_values=("${merged_parameter_values[@]}")
  write_parameter_file "$temp_file" "$parsed_parameter_format"

  printf '%s' "$temp_file"
}

set_config_value() {
  local key="$1"
  local value="$2"

  case "$key" in
    stack_name)
      stack_name="$value"
      ;;
    template_file)
      template_file="$value"
      ;;
    parameter_file)
      parameter_file="$value"
      ;;
    set_param)
      parameter_overrides+=("$value")
      ;;
    assume_role_arn)
      assume_role_arn="$value"
      ;;
    cloudformation_role_arn)
      cloudformation_role_arn="$value"
      ;;
    region)
      region="$value"
      ;;
    profile)
      profile="$value"
      ;;
    capabilities)
      capabilities="$value"
      ;;
    dry_run)
      dry_run="$(parse_bool "$value")"
      ;;
    no_assume_role)
      skip_assume_role="$(parse_bool "$value")"
      ;;
    tag)
      tags+=("$value")
      ;;
    extra_arg)
      extra_args+=("$value")
      ;;
    "")
      ;;
    *)
      error "Unknown config key: $key"
      exit 1
      ;;
  esac
}

load_config_file() {
  local config_file="$1"
  local line=""
  local line_no=0
  local key=""
  local value=""

  assert_file_exists "$config_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))

    line="$(trim "$line")"

    # Skip empty lines and comments
    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    if [[ "$line" != *"="* ]]; then
      error "Invalid config line ${line_no} in ${config_file}: missing '='"
      exit 1
    fi

    key="${line%%=*}"
    value="${line#*=}"

    key="$(trim "$key")"
    value="$(trim "$value")"
    value="$(strip_optional_quotes "$value")"

    set_config_value "$key" "$value"
  done < "$config_file"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        config_file="${2:-}"
        [[ -n "$config_file" ]] || {
          error "--config requires a value"
          usage
          exit 1
        }
        shift 2
        ;;
      --stack-name)
        stack_name="${2:-}"
        shift 2
        ;;
      --template-file)
        template_file="${2:-}"
        shift 2
        ;;
      --parameter-file)
        parameter_file="${2:-}"
        shift 2
        ;;
      --set-param)
        parameter_overrides+=("${2:-}")
        shift 2
        ;;
      --assume-role-arn)
        assume_role_arn="${2:-}"
        shift 2
        ;;
      --cloudformation-role-arn)
        cloudformation_role_arn="${2:-}"
        shift 2
        ;;
      --region)
        region="${2:-}"
        shift 2
        ;;
      --profile)
        profile="${2:-}"
        shift 2
        ;;
      --capabilities)
        capabilities="${2:-}"
        shift 2
        ;;
      --tag)
        tags+=("${2:-}")
        shift 2
        ;;
      --extra-arg)
        extra_args+=("${2:-}")
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --no-assume-role)
        skip_assume_role=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

assume_role() {
  local role_arn="$1"
  local session_name="$2"

  local assume_role_output
  assume_role_output="$(aws sts assume-role \
    --role-arn "$role_arn" \
    --role-session-name "$session_name" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text \
    --no-cli-pager)"

  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$assume_role_output"

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
}

main() {
  require_command aws

  stack_name=""
  template_file=""
  parameter_file=""
  parameter_overrides=()
  assume_role_arn=""
  cloudformation_role_arn=""
  region=""
  profile=""
  capabilities="CAPABILITY_NAMED_IAM"
  dry_run=false
  skip_assume_role=false
  config_file=""

  declare -a tags=()
  declare -a extra_args=()

  # First pass: find config file and collect CLI values
  parse_args "$@"

  # parse_args already loaded CLI values, so rebuild state:
  # reset, load config, then reapply CLI values
  local cli_stack_name="$stack_name"
  local cli_template_file="$template_file"
  local cli_parameter_file="$parameter_file"
  local -a cli_parameter_overrides=("${parameter_overrides[@]}")
  local cli_assume_role_arn="$assume_role_arn"
  local cli_cloudformation_role_arn="$cloudformation_role_arn"
  local cli_region="$region"
  local cli_profile="$profile"
  local cli_capabilities="$capabilities"
  local cli_dry_run="$dry_run"
  local cli_skip_assume_role="$skip_assume_role"
  local -a cli_tags=("${tags[@]}")
  local -a cli_extra_args=("${extra_args[@]}")

  # Reset defaults
  stack_name=""
  template_file=""
  parameter_file=""
  parameter_overrides=()
  assume_role_arn=""
  cloudformation_role_arn=""
  region=""
  profile=""
  capabilities="CAPABILITY_NAMED_IAM"
  dry_run=false
  skip_assume_role=false
  tags=()
  extra_args=()

  # Load config values
  if [[ -n "$config_file" ]]; then
    log "Loading config from '$config_file'"
    load_config_file "$config_file"
  fi

  # Reapply CLI overrides
  [[ -n "$cli_stack_name" ]] && stack_name="$cli_stack_name"
  [[ -n "$cli_template_file" ]] && template_file="$cli_template_file"
  [[ -n "$cli_parameter_file" ]] && parameter_file="$cli_parameter_file"
  [[ -n "$cli_assume_role_arn" ]] && assume_role_arn="$cli_assume_role_arn"
  [[ -n "$cli_cloudformation_role_arn" ]] && cloudformation_role_arn="$cli_cloudformation_role_arn"
  [[ -n "$cli_region" ]] && region="$cli_region"
  [[ -n "$cli_profile" ]] && profile="$cli_profile"
  [[ "$cli_capabilities" != "CAPABILITY_NAMED_IAM" || "$capabilities" == "CAPABILITY_NAMED_IAM" ]] && capabilities="$cli_capabilities"
  [[ "$cli_dry_run" == true ]] && dry_run=true
  [[ "$cli_skip_assume_role" == true ]] && skip_assume_role=true

  if [[ "${#cli_tags[@]}" -gt 0 ]]; then
    tags+=("${cli_tags[@]}")
  fi

  if [[ "${#cli_parameter_overrides[@]}" -gt 0 ]]; then
    parameter_overrides+=("${cli_parameter_overrides[@]}")
  fi

  if [[ "${#cli_extra_args[@]}" -gt 0 ]]; then
    extra_args+=("${cli_extra_args[@]}")
  fi

  [[ -n "$stack_name" ]] || { error "--stack-name is required"; usage; exit 1; }
  [[ -n "$template_file" ]] || { error "--template-file is required"; usage; exit 1; }

  assert_file_exists "$template_file"
  if [[ -n "$parameter_file" ]]; then
    assert_file_exists "$parameter_file"
  fi

  local effective_parameter_file=""
  effective_parameter_file="$(build_effective_parameter_file "$parameter_file" "${parameter_overrides[@]}")"

  if [[ "${#parameter_overrides[@]}" -gt 0 ]]; then
    log "Applying ${#parameter_overrides[@]} parameter override(s) before deploy"
  fi

  local -a aws_base_cmd=(aws)
  if [[ -n "$profile" ]]; then
    aws_base_cmd+=(--profile "$profile")
  fi
  if [[ -n "$region" ]]; then
    aws_base_cmd+=(--region "$region")
  fi
  aws_base_cmd+=(--no-cli-pager)

  if [[ "$skip_assume_role" != true && -n "$assume_role_arn" ]]; then
    log "Assuming caller role"
    assume_role "$assume_role_arn" "deploy-${stack_name}-$(date +%s)"
  fi

  local -a deploy_cmd=(
    "${aws_base_cmd[@]}"
    cloudformation deploy
    --stack-name "$stack_name"
    --template-file "$template_file"
    --capabilities "$capabilities"
    --no-fail-on-empty-changeset
  )

  if [[ -n "$effective_parameter_file" ]]; then
    deploy_cmd+=(--parameter-overrides "file://$effective_parameter_file")
  fi

  if [[ -n "$cloudformation_role_arn" ]]; then
    deploy_cmd+=(--role-arn "$cloudformation_role_arn")
  fi

  if [[ "${#tags[@]}" -gt 0 ]]; then
    deploy_cmd+=(--tags "${tags[@]}")
  fi

  if [[ "${#extra_args[@]}" -gt 0 ]]; then
    deploy_cmd+=("${extra_args[@]}")
  fi

  if [[ "$dry_run" == true ]]; then
    deploy_cmd+=(--no-execute-changeset)
    log "Running in dry-run mode"
  fi

  local -a display_cmd=(
    aws cloudformation deploy
    --stack-name "$stack_name"
    --template-file "$template_file"
    --capabilities "$capabilities"
    --no-fail-on-empty-changeset
  )

  if [[ -n "$effective_parameter_file" ]]; then
    display_cmd+=(--parameter-overrides "file://$effective_parameter_file")
  fi

  if [[ -n "$region" ]]; then
    display_cmd+=(--region "$region")
  fi

  if [[ -n "$profile" ]]; then
    display_cmd+=(--profile "$profile")
  fi

  if [[ -n "$cloudformation_role_arn" ]]; then
    display_cmd+=(--role-arn "$cloudformation_role_arn")
  fi

  if [[ "${#tags[@]}" -gt 0 ]]; then
    display_cmd+=(--tags "${tags[@]}")
  fi

  if [[ "${#extra_args[@]}" -gt 0 ]]; then
    display_cmd+=("${extra_args[@]}")
  fi

  if [[ "$dry_run" == true ]]; then
    display_cmd+=(--no-execute-changeset)
  fi

  log "Deploying stack '${stack_name}'"
  printf 'Executing:'
  printf ' %q' "${display_cmd[@]}"
  printf '\n'

  if ! "${deploy_cmd[@]}"; then
    error "Deploy failed, fetching recent stack events"
    "${aws_base_cmd[@]}" cloudformation describe-stack-events \
      --stack-name "$stack_name" \
      --max-items 10
    exit 1
  fi

  log "Deployment finished successfully"
}

main "$@"