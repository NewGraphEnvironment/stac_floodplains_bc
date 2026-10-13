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
- Phases 1-6 landed as six atomic commits (abf4783, a63c75f, d07023f, 4f52666, b4e5471,
  ad47821), each carrying its own checkbox flips.
- Issue #74's body rewritten to what shipped (the crate dependency and the COG-rebuild
  premise both removed); crate#23 commented with the no-schema decision and the two
  processing-schema measurements.
- Verified: prov_fields-check.py 38/0; catalogue_release-check.sh ALL PASS (case 16 new);
  WSG=larl test_pipeline.R PASS with all 10 assets byte-identical to the live item;
  attribution_drift-check.py clean.
- Next: /code-check branch, then archive and open the PR.

