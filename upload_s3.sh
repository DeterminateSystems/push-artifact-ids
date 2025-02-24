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
  if [[ "$GITHUB_REF_TYPE" == "tag" ]]; then
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
    md5="$(openssl dgst -md5 "$artifact" | cut -d' ' -f2)"
    obj="$(aws s3api head-object --bucket "$AWS_BUCKET" --key "$artifact_path" || echo '{}')"
    obj_md5="$(jq -r .ETag <<<"$obj" | jq -r)" # head-object call returns ETag quoted, so `jq -r` again to unquote it

    if [[ "$md5" == "$obj_md5" ]]; then
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

sync_args+=(--content-disposition "attachment; filename=\"$IDS_BINARY_PREFIX\"")

aws s3 sync "$DEST"/ s3://"$AWS_BUCKET"/"$DEST"/ "${sync_args[@]}"
if ! is_tag; then
  aws s3 sync "$GIT_ISH"/ s3://"$AWS_BUCKET"/"$GIT_ISH"/ "${sync_args[@]}"
fi

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
