"""Builds the iPhone "Prosperity Voice" shortcut (and a text-input test version).

Run: python3 build_shortcut.py && shortcuts sign --mode anyone --input "Prosperity Voice.wflow" --output "Prosperity Voice.shortcut"
Steps: Dictate Text (stop on tap) -> Use Model (Apple Intelligence, Private Cloud Compute by default)
-> Copy to Clipboard -> Show Notification. "PV Cleanup Test" takes text input instead of dictation,
for testing the prompt with: shortcuts run "PV Cleanup Test" -i in.txt -o out.txt
"""
import plistlib, uuid, sys
OBJ="￼"
# Same instructions the Mac app gives Apple's model (exported with:
#   ProsperityVoice --print-instructions apple > cleanup-instructions.txt)
import os
HERE = os.path.dirname(os.path.abspath(__file__))
PROMPT = open(os.path.join(HERE, "cleanup-instructions.txt")).read().strip() + "\n\n<transcript>" + OBJ + "</transcript>"
assert all(ord(c) < 0x10000 for c in PROMPT), "Shortcuts text ranges are UTF-16; keep the prompt in the BMP"
def tok(string, ranges): return {"Value":{"string":string,"attachmentsByRange":ranges},"WFSerializationType":"WFTextTokenString"}
def out_ref(u,name): return {"Type":"ActionOutput","OutputUUID":u,"OutputName":name}
def build(name, dictate):
    acts=[]; src={"Type":"ExtensionInput"}
    if dictate:
        ud=str(uuid.uuid4()).upper()
        acts.append({"WFWorkflowActionIdentifier":"is.workflow.actions.dictatetext",
                     "WFWorkflowActionParameters":{"UUID":ud,"WFDictateTextStopListening":"On Tap","WFSpeechLanguage":"en-US"}})
        src=out_ref(ud,"Dictated Text")
    ul=str(uuid.uuid4()).upper()
    p=PROMPT
    acts.append({"WFWorkflowActionIdentifier":"is.workflow.actions.askllm",
                 "WFWorkflowActionParameters":{"UUID":ul,"WFLLMPrompt":tok(p,{"{%d, 1}"%p.index(OBJ):src})}})
    resp=out_ref(ul,"Response")
    if dictate:
        acts.append({"WFWorkflowActionIdentifier":"is.workflow.actions.setclipboard",
                     "WFWorkflowActionParameters":{"WFInput":{"Value":resp,"WFSerializationType":"WFTextTokenAttachment"}}})
        acts.append({"WFWorkflowActionIdentifier":"is.workflow.actions.notification",
                     "WFWorkflowActionParameters":{"WFNotificationActionTitle":"Copied. Tap a text box and paste.",
                       "WFNotificationActionBody":tok(OBJ,{"{0, 1}":resp}),"WFNotificationActionSound":False}})
    else:
        acts.append({"WFWorkflowActionIdentifier":"is.workflow.actions.output",
                     "WFWorkflowActionParameters":{"WFOutput":tok(OBJ,{"{0, 1}":resp})}})
    wf={"WFWorkflowClientVersion":"3000","WFWorkflowMinimumClientVersion":900,
        "WFWorkflowIcon":{"WFWorkflowIconStartColor":4271458815,"WFWorkflowIconGlyphNumber":59792},
        "WFWorkflowInputContentItemClasses":["WFStringContentItem"],"WFWorkflowTypes":[] if dictate else [],
        "WFWorkflowActions":acts}
    plistlib.dump(wf, open(name+".wflow","wb"), fmt=plistlib.FMT_BINARY)
build(os.environ.get("TEST_NAME", "PV Cleanup Test"), False)
# Mac helper: a plain pipe to Apple's Private Cloud Compute model. The Mac app sends the whole
# prompt (its own instructions + text) as input, since apps can't call that model directly
# without a paid developer entitlement.
PROMPT = OBJ
build("Prosperity Voice Helper", False)
build("Prosperity Voice", True)
