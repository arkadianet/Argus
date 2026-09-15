# Preview fixtures

Locally generated 2048×2 red images: static RGB PNG, baseline JPEG and
progressive JPEG. They contain no downloaded artwork or wallet metadata.
Tests use these to exercise native decode target sizes. Hostile byte streams,
header mutations and response metadata are constructed in preview_policy_test.
