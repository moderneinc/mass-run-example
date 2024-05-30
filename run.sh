#!/bin/bash

# if `mod` already exists in the path, use it, otherwise use the local version
mod_command=$(command -v mod)
if [ -z "$mod_command" ]; then
  mod_command="java -jar mod.jar"
fi

recipe_id="io.moderne.RecipeList"

function generate_random_id(){
  timestamp=$(date +%Y%m%d%H%M%S)
  local random_string=$(openssl rand -base64 8 | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
  random_id="${timestamp}${random_string}"
  echo $random_id
}

function runAllOrganisations() {
  while IFS= read -r line; do
        # Check if the line resembles an organization name pattern
        if [[ "$line" =~ ^[[:space:]]*[[:graph:]].*\([0-9]+\)$ ]]; then
            # Extract the organization name excluding repo count
            org_name=$(echo "$line" | sed -E 's/\s*\([0-9]+\)$//' | xargs)

            # Check if the extracted organization name is not empty
            if [ -n "$org_name" ]; then
                run_organization "$org_name"
            fi
        fi
    done < <($mod_command config moderne organizations show)
}

function runListedOrganisations() {
    while IFS= read -r org; do
        run_organization "$org"
    done < organization-list.txt
}

function run() {
  # Install all known recipes
  # $mod_command config recipes moderne sync
  # Install a specific recipe
  $mod_command config recipes jar install org.openrewrite.recipe:rewrite-static-analysis:LATEST
  # Install recipe list yaml, containing the recipes we want to run
  $mod_command config recipes yaml install recipe.yml
  # Uncomment/comment the following lines to run on all organizations or only listed organizations
  # runAllOrganisations
  runListedOrganisations
}

function run_organization() {
  local org_name="$1"
  # Encode the organization name for use in paths and urls
  local org_encoded="$(perl -MURI::Escape -e '$input=$ARGV[0];$input=~s/ /_/g; print uri_escape(lc($input));' "$org_name")"
  echo "Running org: $org_name ($org_encoded)"
  # Prepare working environment
  id=$(generate_random_id)
  local workingdir="workingdir/$org_encoded/$id"
  mkdir -p $workingdir
  # Running commands
  $mod_command git clone moderne $workingdir "$org_name" --metadata
  $mod_command build $workingdir
  $mod_command run $workingdir --recipe $recipe_id
  $mod_command log runs add $workingdir $workingdir/runs.zip --last-run --organization "$org_name"
  # Saving results to artifactory
  curl -XPUT \
    --user $ARTIFACTORY_USER:$ARTIFACTORY_PASSWORD \
    --upload-file $workingdir/runs.zip \
    --fail \
    $ARTIFACTORY_UPLOAD_URL/$org_encoded/$id/runs.zip \

  rm -rf $workingdir
}

# Continuously build and run repositories in a loop
# If you'd like to run this script once, or on a schedule, remove the while loop
while true; do
  run
done

