# Releasing SpellPad Studio

One codebase and one combined `.toc` serve both clients. The `.toc` line

    ## Interface: 120105, 16001

lists the retail interface number first and Forever's (16001) second. When a retail
patch lands, update the first number; get the right one in game with
`/dump (select(4, GetBuildInfo()))`.

## Before a release

1. Test the change on both clients with `docs/rundown-template.md`. A point that
   can't be run on Forever stays on its "pending" list.
2. Run `python tools/check.py` (needs `pip install lupa`). It must print 0 errors:
   every `.lua` file compiles as Lua 5.1, the `.toc` and the files on disk agree
   (exact file-name case, because the packager runs on Linux), line endings are
   CRLF in the `.lua` files and LF in the `.toc`, and client tags are valid.
3. Bump `## Version` in `SpellPadStudio.toc`.

## Cutting the release

Publishing is automatic: pushing a version tag runs `.github/workflows/release.yml`,
which packages the addon and uploads it to CurseForge (project 1747177) and to a
GitHub release. Pushing a branch uploads nothing.

    git tag v1.2.1
    git push origin v1.2.1

- `v1.2.1` is a Release, `v1.2.1-beta1` a Beta, `v1.2.1-alpha1` an Alpha. Use a beta
  tag first when unsure.
- The workflow needs the repository secret `CF_API_KEY` (a CurseForge API token from
  https://wow.curseforge.com/account/api-tokens). If an upload fails with 401/403,
  the token was revoked or expired: make a new one and replace the secret.
- Watch the run under the repository's Actions tab. A failed run can be fixed and
  re-run by deleting the tag (`git push --delete origin v1.2.1`) and tagging again.
- CurseForge may not know game version 16001 (Forever); if the log complains, that
  number is the one to look at.

The packager reads `.pkgmeta`: it builds a zip whose folder is `SpellPadStudio`,
bundles `libs/`, and leaves out the development files (`tools/`, `docs/`,
`reference/`, this file and the README). Line endings are kept as they are in the
repository (`.gitattributes` turns conversion off).

## Notes

- Never rename a file by case alone without telling git (`git mv a.lua tmp.lua`,
  then `git mv tmp.lua A.lua`): Windows hides the difference and the packaged zip
  would not match the `.toc`.
- New `.lua` files go in the `.toc`; the check fails if one is missing.
