// Get the workspace object
let workspace = Workspace.find("callsheet");

// Check if the workspace exists
if (workspace) {
  // Activate the workspace
  workspace.activate();

  // Get the newly created draft (assuming it was created in the previous step)
  let newDraft = draft; 

  //check if the draft is valid
  if (newDraft){
    // Load the draft into the editor
    editor.load(newDraft);
  } else {
    // Log an error if the draft is not valid
    console.error("Error: New draft is not valid")
  }
} else {
  // Log an error if the workspace doesn't exist
  console.error("Workspace 'callsheet' not found.");
}