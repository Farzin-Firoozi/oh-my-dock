#!/bin/sh
# oh-my-dock profile: 'Work'
# generator: oh-my-dock 0.0.1
set -eu
if ! command -v dockutil >/dev/null 2>&1; then
  printf '%s\n' 'dockutil is required. Install it with: brew install dockutil' >&2
  exit 1
fi
dockutil --remove 'all' --no-restart
dockutil --add '/Applications/Figma.app' --type 'file' --section 'apps' --position '1' --no-restart
dockutil --add '' --type 'spacer' --section 'apps' --position '2' --label='oh-my-dock-spacer' --no-restart
dockutil --add '' --type 'small-spacer' --section 'apps' --position '3' --label='oh-my-dock-spacer' --no-restart
dockutil --add "$HOME"'/Applications/Safari.app' --type 'file' --section 'apps' --position '4' --no-restart
dockutil --add "$HOME"'/Downloads' --type 'directory' --section 'others' --position '1' --label='Downloads' --view 'grid' --display 'folder' --sort 'dateadded' --no-restart
dockutil --add 'https://example.com/docs' --type 'url' --section 'others' --position '2' --label='Docs' --no-restart
dockutil --add "$HOME"'/notes.txt' --type 'file' --section 'others' --position '3' --label='Notes' --no-restart
dockutil --add '' --type 'flex-spacer' --section 'others' --position '4' --label='oh-my-dock-spacer' --no-restart
defaults write com.apple.dock tilesize -float '48'
defaults write com.apple.dock magnification -bool 'true'
defaults write com.apple.dock largesize -float '96'
defaults write com.apple.dock orientation -string 'left'
defaults write com.apple.dock autohide-delay -float '0.5'
killall Dock
