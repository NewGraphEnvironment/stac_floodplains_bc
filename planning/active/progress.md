# Progress — Move the nge: item fields to standard or descriptive names (#74)

## Session 2026-10-13

- Plan-mode exploration: read the twelve-field contract across `item_create.py`,
  `item_validate.py`, `02_raster_tag.py`, `catalogue_release.sh` and `test_pipeline.R`;
  read the two sibling migrations (`stac_airphoto_bc#47`, `stac_pointcloud_bc#2`) and crate's
  schema rules; fetched the processing v1.2.0 schema and measured the live per-field census.
- Four forks answered by the user: `link:` prefix, omit-when-absent, `landcover:stac_url` stays
  a property, no crate schema.
- Plan review ran concurrently; its central finding (three live populations, not two) was
  verified against the API and the plan's per-section arm replaced by a per-field census.
- Created branch `74-move-the-nge-item-fields-to-standard-or` off main.
- Next: Phase 1, the map and the writer.
