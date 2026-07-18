# Contributing to VPlayer

By submitting a contribution, you certify that you have the right to
submit it and license it under GPL-3.0-only together with the complete
`LICENSE.APPSTORE-EXCEPTION` in this repository. You retain your copyright.

Every new Swift or Metal source file must begin with:

```text
// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
```

Do not use an SPDX `WITH` expression for the project-specific exception
unless SPDX tooling later recognizes an exact registered identifier.
Preserve upstream notices when incorporating third-party material and add
its origin, pinned revision, modifications, and license to
`THIRD_PARTY_NOTICES`.

Before submitting a change, run `Scripts/test.sh` and
`Scripts/verify-licenses.sh`. Never add files below `/docs/`; they are
local design and planning material.
