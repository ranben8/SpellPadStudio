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

    git tag v1.2.1
    git push origin v1.2.1

The packager reads `.pkgmeta`: it builds a zip whose folder is `SpellPadStudio`,
bundles `libs/`, and leaves out the development files (`tools/`, `docs/`,
`reference/`, this file and the README). Line endings are kept as they are in the
repository (`.gitattributes` turns conversion off).

## Notes

- Never rename a file by case alone without telling git (`git mv a.lua tmp.lua`,
  then `git mv tmp.lua A.lua`): Windows hides the difference and the packaged zip
  would not match the `.toc`.
- New `.lua` files go in the `.toc`; the check fails if one is missing.
