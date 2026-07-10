# 04_s3_upload.R — sync the COGs + vector assets to S3.
#
# aws s3 sync uploads only new/changed objects. Local data/stac/ mirrors the
# bucket root: <wsg>/{classified_*,transition_*}.tif + floodplain_landcover.gpkg.

bucket <- "stac-floodplains-bc"
local_dir <- file.path("data", "stac")

if (!dir.exists(local_dir)) {
  stop("No COGs found at ", local_dir, " — run 02_cog.R first")
}

# Exclude dotfiles at the root AND nested (macOS drops .DS_Store into per-WSG dirs);
# exclude *.json (item/collection JSON is uploaded by 05). No --size-only: a re-run
# after fixing an upstream number must re-upload even if the compressed size matches.
cmd <- sprintf(
  "aws s3 sync %s s3://%s --exclude '.*' --exclude '*/.*' --exclude '*.json'",
  local_dir, bucket
)

message("Running: ", cmd)
exit_code <- system(cmd)

if (exit_code != 0) {
  stop("S3 sync failed with exit code ", exit_code)
}

message("Sync complete")
