#!/usr/bin/env bash
set -eux

ARTIFACTS_DIRECTORY="$1"
TYPE="$2"
TYPE_ID="$3"
GIT_ISH="$4"

if [ "$TYPE" == "tag" ]; then
  DEST="${TYPE_ID}"
else
  DEST="${TYPE}_${TYPE_ID}"
fi

is_tag() {
  if [[ "$TYPE" == "tag" ]]; then
    return 0
  else
    return 1
  fi
}

# If the revision directory has already been created in S3 somehow, we don't want to reupload
if aws s3 ls "$AWS_BUCKET"/"$GIT_ISH"/; then
  # Only exit if it's not a tag (since we're tagging a commit previously pushed to main)
  if ! is_tag; then
    echo "Revision $GIT_ISH was already uploaded; exiting"
    exit 1
  fi
fi

mkdir "$DEST"
mkdir "$GIT_ISH"

find "$ARTIFACTS_DIRECTORY/" -type f -print0 |
    while IFS= read -r -d '' architecture; do
  chmod +x "$architecture"
  architecture_only=$(basename "$architecture");
  cp "$architecture" "$DEST/${IDS_BINARY_PREFIX}-${architecture_only}"
  cp "$architecture" "$GIT_ISH/${IDS_BINARY_PREFIX}-${architecture_only}"
done

# If any artifact already exists in S3 and the hash is the same, we don't want to reupload
check_reupload() {
  dest="$1"

  find "$ARTIFACTS_DIRECTORY/" -type f -print0 |
  while IFS= read -r -d '' artifact; do
    artifact_path="$dest"/"$(basename "$artifact")"
    artifact_path="$(echo "$artifact_path" | tr -s /)"

    md5="$(openssl dgst -md5 "$artifact" | cut -d' ' -f2)"
    obj="$(aws s3api head-object --bucket "$AWS_BUCKET" --key "$artifact_path" || echo '{}')"
    obj_md5="$(jq -r .ETag <<<"$obj" | jq -r)" # head-object call returns ETag quoted, so `jq -r` again to unquote it

    # Object doesn't exist, so let's check the next one
    if [[ "$obj_md5" == "null" ]]; then
      continue
    fi

    if [[ "$md5" != "$obj_md5" ]]; then
      echo "Artifact $artifact was already uploaded; exiting"
      # If we already uploaded to a tag, that's probably bad
      is_tag && exit 1 || exit 0
    fi
  done
}

check_reupload "$DEST"
if ! is_tag; then
  check_reupload "$GIT_ISH"
fi

sync_args=()

if [[ "$SKIP_ACL" != "true" ]]; then
  sync_args+=(--acl public-read)
fi

# NOTE(cole-h): never allow reuploading to a tag
if is_tag; then
  sync_args+=(--if-none-match '*')
fi

sync_args+=(--content-disposition "attachment; filename=\"$IDS_BINARY_PREFIX\"")

# NOTE(cole-h): never allow reuploading to a rev
if ! is_tag; then
  find "$GIT_ISH/" -type f -print0 |
    while IFS= read -r -d '' artifact_path; do
      artifact_path="$(echo "$artifact_path" | tr -s /)"
      aws s3api put-object --bucket "$AWS_BUCKET" --key "$artifact_path" --body "$artifact_path" "${sync_args[@]}" --if-none-match '*'
    done
fi

find "$DEST/" -type f -print0 |
  while IFS= read -r -d '' artifact_path; do
    artifact_path="$(echo "$artifact_path" | tr -s /)"
    aws s3api put-object --bucket "$AWS_BUCKET" --key "$artifact_path" --body "$artifact_path" "${sync_args[@]}"
  done

cat <<-EOF >> $GITHUB_STEP_SUMMARY
This commit's ${IDS_PROJECT} artifacts can be fetched via:

EOF

find "$ARTIFACTS_DIRECTORY/" -type f -print0 |
    while IFS= read -r -d '' architecture; do
    architecture=$(basename "$architecture");
    cat <<-EOF >> $GITHUB_STEP_SUMMARY
\`\`\`
curl --output "$IDS_BINARY_PREFIX" --proto '=https' --tlsv1.2 -sSf -L 'https://install.determinate.systems/${IDS_PROJECT}/rev/$GIT_ISH/${architecture}'
\`\`\`

EOF
done


cat <<-EOF >> $GITHUB_STEP_SUMMARY
Or generally from this ${TYPE}:

EOF

find "$ARTIFACTS_DIRECTORY/" -type f -print0 |
    while IFS= read -r -d '' architecture; do
    architecture=$(basename "$architecture");
    cat <<-EOF >> $GITHUB_STEP_SUMMARY
\`\`\`
curl --output "$IDS_BINARY_PREFIX" --proto '=https' --tlsv1.2 -sSf -L 'https://install.determinate.systems/${IDS_PROJECT}/${TYPE}/${TYPE_ID}/${architecture}'
\`\`\`

EOF
done
