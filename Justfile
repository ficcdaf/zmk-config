default:
    @just --list --unsorted

config := absolute_path('config')
build := absolute_path('.build')
out := absolute_path('firmware')
draw := absolute_path('draw')

# parse combos.dtsi and adjust settings to not run out of slots
_parse_combos:
    #!/usr/bin/env bash
    set -euo pipefail
    cconf="{{ config / 'combos.dtsi' }}"
    if [[ -f $cconf ]]; then
        # set MAX_COMBOS_PER_KEY to the most frequent combos count
        count=$(
            tail -n +10 $cconf |
                grep -Eo '[LR][TMBH][0-9]' |
                sort | uniq -c | sort -nr |
                awk 'NR==1{print $1}'
        )
        sed -Ei "/CONFIG_ZMK_COMBO_MAX_COMBOS_PER_KEY/s/=.+/=$count/" "{{ config }}"/*.conf
        echo "Setting MAX_COMBOS_PER_KEY to $count"

        # set MAX_KEYS_PER_COMBO to the most frequent key count
        count=$(
            tail -n +10 $cconf |
                grep -o -n '[LR][TMBH][0-9]' |
                cut -d : -f 1 | uniq -c | sort -nr |
                awk 'NR==1{print $1}'
        )
        sed -Ei "/CONFIG_ZMK_COMBO_MAX_KEYS_PER_COMBO/s/=.+/=$count/" "{{ config }}"/*.conf
        echo "Setting MAX_KEYS_PER_COMBO to $count"
    fi

# parse build.yaml and filter targets by expression
_parse_targets $expr:
    #!/usr/bin/env bash
    attrs="[.board, .shield, .snippet]"
    filter="(($attrs | map(. // [.]) | combinations), ((.include // {})[] | $attrs)) | join(\",\")"
    echo "$(yq -r "$filter" build.yaml | grep -v "^," | grep -i "${expr/#all/.*}")"

# build firmware for single board & shield combination
_build_single $board $shield $snippet *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    artifact="${shield:+${shield// /+}-}${board}"
    build_dir="{{ build / '$artifact' }}"

    echo "Building firmware for $artifact..."
    west build -s zmk/app -d "$build_dir" -b $board {{ west_args }} ${snippet:+-S "$snippet"} -- \
        -DZMK_CONFIG="{{ config }}" ${shield:+-DSHIELD="$shield"}

    if [[ -f "$build_dir/zephyr/zmk.uf2" ]]; then
        mkdir -p "{{ out }}" && cp "$build_dir/zephyr/zmk.uf2" "{{ out }}/$artifact.uf2"
    else
        mkdir -p "{{ out }}" && cp "$build_dir/zephyr/zmk.bin" "{{ out }}/$artifact.bin"
    fi

# build firmware for matching targets
build expr *west_args: _parse_combos
    #!/usr/bin/env bash
    set -euo pipefail
    targets=$(just _parse_targets {{ expr }})

    [[ -z $targets ]] && echo "No matching targets found. Aborting..." >&2 && exit 1
    echo "$targets" | while IFS=, read -r board shield snippet; do
        just _build_single "$board" "$shield" "$snippet" {{ west_args }}
    done
    just draw

# clear build cache and artifacts
clean:
    rm -rf {{ build }} {{ out }}

# clear all automatically generated files
clean-all: clean
    rm -rf .west zmk

# clear nix cache
clean-nix:
    nix-collect-garbage --delete-old

# parse & plot keymap
draw:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Parsing keymap..."
    keymap -c "{{ draw }}/config.yaml" parse -z "{{ config }}/corne.keymap" >"{{ draw }}/base.yaml"
    echo "Drawing vector graphics..."
    keymap -c "{{ draw }}/config.yaml" draw "{{ draw }}/base.yaml" >"{{ draw }}/base.svg"
    # put inkscape command here
    echo "Converting to png..."
    inkscape --export-type png --export-filename {{ draw }}/keymap.png --export-dpi 300 --export-background=gray {{ draw }}/base.svg > /dev/null 2>&1

# initialize west
init:
    west init -l config
    west update
    west zephyr-export

# list build targets
list:
    @just _parse_targets all | sed 's/,$//' | sort | column

# update west
update:
    west update

# upgrade zephyr-sdk and python dependencies
upgrade-sdk:
    nix flake update --flake .

# Flash the firmware
hardflash side:
    #!/usr/bin/env bash
    if [[ {{side}} == "left" || {{side}} == "right" ]]; then
        echo "Flashing: {{side}}"
        file {{out}}/corne_{{side}}+nice_view_adapter+nice_view-nice_nano_v2.uf2 || exit
        cp {{out}}/corne_{{side}}+nice_view_adapter+nice_view-nice_nano_v2.uf2 /run/media/fic/NICENANO
    else
        echo "Provide either 'left' or 'right'!"
        exit 1
    fi

flash side:
  #!/usr/bin/env bash
  timeout=30
  elapsed=0

  if [[ {{side}} == "left" || {{side}} == "right" ]]; then
      echo "Flashing: {{side}}"
      
      # Verify the file exists before proceeding
      file {{out}}/corne_{{side}}+nice_view_adapter+nice_view-nice_nano_v2.uf2 || exit 1

      echo "Waiting for /run/media/fic/NICENANO to appear..."

      # Wait for the directory with a timeout using `until`
      until [[ -d "/run/media/fic/NICENANO" ]] || ((elapsed >= timeout)); do
          sleep 1
          ((elapsed++))
      done

      # Check if the timeout was reached
      if ((elapsed >= timeout)); then
          echo "Timeout reached! NICENANO drive not found."
          exit 1
      else
          echo "NICENANO drive found, flashing now..."
      fi

      # Copy the file after the directory is detected
      cp {{out}}/corne_{{side}}+nice_view_adapter+nice_view-nice_nano_v2.uf2 /run/media/fic/NICENANO
      echo "Flashing done."
  else
      echo "Provide either 'left' or 'right'!"
      exit 1
  fi
