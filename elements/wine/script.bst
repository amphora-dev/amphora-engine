kind: import

description: |
  ci/wine.sh as a build dependency of wine/wine.bst. It is a separate
  element (not a local source of wine/wine.bst) so that a BuildStream
  workspace on the Wine source still has the script.

sources:
- kind: local
  path: ci/wine.sh

config:
  target: /opt/amphora/ci
