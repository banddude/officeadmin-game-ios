#!/usr/bin/env python3
"""Generate OfficeAdminGame.xcodeproj from the source tree.

The orchestrator that drives this repo has no Xcode, so the project file is
regenerable instead of hand-edited: this script walks App/, Core/, Scenes/
and OfficeAdminGameTests/, emits project.pbxproj plus the shared scheme, and
is checked in next to them. Run it from the repo root after adding files:

    python3 tools/gen_project.py

Deterministic UUIDs (sha1 of the object name, truncated) keep regeneration
diff-clean as long as the file list does not change.
"""

from __future__ import annotations

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

APP_NAME = "OfficeAdminGame"
TEST_NAME = "OfficeAdminGameTests"

# Sources compiled into the app target.
APP_SOURCE_DIRS = ["App", "Core", "Scenes", "Assets"]
# Sources compiled into the test target (logic tests, no host app: the Core
# and Scenes layers are pure enough to test standalone).
TEST_SOURCE_DIRS = ["Core", "OfficeAdminGameTests"]
# Resources copied into the test bundle (fixture JSON).
TEST_RESOURCE_DIRS = [os.path.join("OfficeAdminGameTests", "Fixtures")]

DEPLOYMENT_TARGET = "17.0"
BUNDLE_ID = "com.officeadmin.game"


def u(name: str) -> str:
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def walk_files(dirs, predicate):
    out = []
    for d in dirs:
        base = os.path.join(ROOT, d)
        if not os.path.isdir(base):
            continue
        for cur, subdirs, files in os.walk(base):
            subdirs.sort()
            for f in sorted(files):
                if predicate(f):
                    out.append(os.path.relpath(os.path.join(cur, f), ROOT))
    return sorted(set(out))


def ftype(path: str) -> str:
    if path.endswith(".swift"):
        return "sourcecode.swift"
    if path.endswith(".json"):
        return "text.json"
    return "file"


class FileRef:
    def __init__(self, path):
        self.path = path
        self.uuid = u(f"fileref::{path}")
        self.type = ftype(path)

    def decl(self):
        return (f"\t\t{self.uuid} /* {self.path} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = {self.type}; path = {os.path.basename(self.path)}; "
                f'sourceTree = "<group>"; }};')


class BuildFile:
    def __init__(self, ref: FileRef, in_resources=False):
        self.ref = ref
        self.uuid = u(f"buildfile::{ref.path}::{in_resources}")
        self.in_resources = in_resources

    def decl(self):
        s = ""
        if self.in_resources:
            s = "settings = {ATTRIBUTES = (RemoveHeadersOnCopy,); }; "
        # Every plist object entry must terminate with };
        return (f"\t\t{self.uuid} /* {self.ref.path} in {'Resources' if self.in_resources else 'Sources'} */ = "
                f"{{isa = PBXBuildFile; fileRef = {self.ref.uuid} /* {self.ref.path} */; {s}}};")


class Group:
    def __init__(self, dirpath):
        # UUID keyed by the full repo-relative dir (unique); the emitted
        # `path` is just the last segment, because PBXGroup paths resolve
        # relative to the PARENT group.
        self.dirpath = dirpath
        self.uuid = u(f"group::{dirpath}")
        self.path = os.path.basename(dirpath) or dirpath
        self.children = []  # (uuid, comment)
        self.name_only = False  # display-only groups (Products) use `name`

    def decl(self):
        lines = [f"\t\t{self.uuid} /* {self.dirpath} */ = {{",
                 "\t\t\tisa = PBXGroup;",
                 "\t\t\tchildren = ("]
        for cu, cn in self.children:
            lines.append(f"\t\t\t\t{cu} /* {cn} */,")
        if self.name_only:
            lines += ["\t\t\t);", f"\t\t\tname = {self.path};",
                      '\t\t\tsourceTree = "<group>";', "\t\t};"]
        else:
            lines += ["\t\t\t);",
                      f"\t\t\tpath = {self.path};",
                      '\t\t\tsourceTree = "<group>";',
                      "\t\t};"]
        return lines


def build_groups(files):
    """Nested PBXGroup tree mirroring directories; returns {dirpath: Group}."""
    groups = {}

    def group_for(dirpath):
        if dirpath not in groups:
            g = Group(dirpath)
            groups[dirpath] = g
            if dirpath != "":
                parent = group_for(os.path.dirname(dirpath))
                parent.children.append((g.uuid, g.path))
        return groups[dirpath]

    for f in files:
        d, base = os.path.split(f)
        g = group_for(d)
        g.children.append((u(f"fileref::{f}"), f))
    # children were appended in file order; keep subgroups first then files,
    # both alphabetical, matching Xcode's own layout.
    for g in groups.values():
        g.children.sort(key=lambda c: (c[1].endswith(".swift"), c[1]))
    return groups


def config_decl(key, name, settings):
    lines = [f"\t\t{u(key)} /* {name} */ = {{",
             "\t\t\tisa = XCBuildConfiguration;",
             "\t\t\tbuildSettings = {"]
    for k in sorted(settings):
        v = settings[k]
        if isinstance(v, list):
            v = "(" + ", ".join(f'"{x}"' for x in v) + ")"
        elif isinstance(v, bool):
            v = "YES" if v else "NO"
        else:
            v = f'"{v}"'
        lines.append(f"\t\t\t\t{k} = {v};")
    lines += ["\t\t\t};", f"\t\t\tname = {name};", "\t\t};"]
    return lines


def main():
    app_sources = walk_files(APP_SOURCE_DIRS, lambda f: f.endswith(".swift"))
    test_sources = walk_files(TEST_SOURCE_DIRS, lambda f: f.endswith(".swift"))
    test_resources = walk_files(TEST_RESOURCE_DIRS,
                                lambda f: not f.startswith(".") and not f.endswith(".swift"))

    all_paths = sorted(set(app_sources + test_sources + test_resources))
    refs = {p: FileRef(p) for p in all_paths}
    app_builds = [BuildFile(refs[p]) for p in app_sources]
    test_source_builds = [BuildFile(refs[p]) for p in test_sources]
    test_resource_builds = [BuildFile(refs[p], in_resources=True) for p in test_resources]

    groups = build_groups(all_paths)
    main_group_uuid = u("group::main")
    products_group = Group("__products__")
    products_group.uuid = u("group::products")
    products_group.path = "Products"
    products_group.name_only = True
    app_product = (u(f"product::{APP_NAME}"), f"{APP_NAME}.app")
    test_product = (u(f"product::{TEST_NAME}"), f"{TEST_NAME}.xctest")
    products_group.children = [app_product, test_product]

    app_target = u(f"target::{APP_NAME}")
    test_target = u(f"target::{TEST_NAME}")
    app_sources_phase = u(f"phase::sources::{APP_NAME}")
    test_sources_phase = u(f"phase::sources::{TEST_NAME}")
    app_res_phase = u(f"phase::resources::{APP_NAME}")
    test_res_phase = u(f"phase::resources::{TEST_NAME}")
    fw_phase_app = u(f"phase::frameworks::{APP_NAME}")
    fw_phase_test = u(f"phase::frameworks::{TEST_NAME}")
    dep = u("dep::tests->app")
    proxy = u("proxy::tests->app")
    project = u("project::self")

    L = []
    w = L.append
    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tobjectVersion = 56;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjects = {")
    w("")
    w("/* Begin PBXBuildFile section */")
    for b in app_builds + test_source_builds + test_resource_builds:
        w(b.decl())
    w("/* End PBXBuildFile section */")
    w("")
    w("/* Begin PBXFileReference section */")
    for p in all_paths:
        w(refs[p].decl())
    w(f'\t\t{app_product[0]} /* {app_product[1]} */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    w(f'\t\t{test_product[0]} /* {test_product[1]} */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {TEST_NAME}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')
    w("/* End PBXFileReference section */")
    w("")
    w("/* Begin PBXContainerItemProxy section */")
    w(f"\t\t{proxy} /* PBXContainerItemProxy */ = {{")
    w("\t\t\tisa = PBXContainerItemProxy;")
    w(f"\t\t\tcontainerPortal = {project} /* Project object */;")
    w("\t\t\tproxyType = 1;")
    w(f"\t\t\tremoteGlobalIDString = {app_target};")
    w(f"\t\t\tremoteInfo = {APP_NAME};")
    w("\t\t};")
    w("/* End PBXContainerItemProxy section */")
    w("")
    for phase in (fw_phase_app, fw_phase_test):
        if phase == fw_phase_app:
            w("/* Begin PBXFrameworksBuildPhase section */")
        w(f"\t\t{phase} /* Frameworks */ = {{")
        w("\t\t\tisa = PBXFrameworksBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")
    w("")
    w("/* Begin PBXGroup section */")
    for g in sorted(groups.values(), key=lambda g: g.uuid):
        w("\n".join(g.decl()))
    w("\n".join(products_group.decl()))
    w(f"\t\t{main_group_uuid} /* main */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    tops = sorted({p.split("/")[0] for p in all_paths})
    for t in tops:
        w(f"\t\t\t\t{groups[t].uuid} /* {t} */,")
    w(f"\t\t\t\t{products_group.uuid} /* Products */,")
    w("\t\t\t);")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w("/* End PBXGroup section */")
    w("")
    w("/* Begin PBXNativeTarget section */")
    for tid, tname, sources_phase, res_phase, product, ptype, has_dep in (
        (app_target, APP_NAME, app_sources_phase, app_res_phase, app_product,
         "com.apple.product-type.application", False),
        (test_target, TEST_NAME, test_sources_phase, test_res_phase, test_product,
         "com.apple.product-type.bundle.unit-test", True),
    ):
        w(f"\t\t{tid} /* {tname} */ = {{")
        w("\t\t\tisa = PBXNativeTarget;")
        w(f'\t\t\tbuildConfigurationList = {u("configlist::target::" + tname)} /* Build configuration list for PBXNativeTarget "{tname}" */;')
        w("\t\t\tbuildPhases = (")
        w(f"\t\t\t\t{sources_phase} /* Sources */,")
        w(f"\t\t\t\t{fw_phase_app if tname == APP_NAME else fw_phase_test} /* Frameworks */,")
        w(f"\t\t\t\t{res_phase} /* Resources */,")
        w("\t\t\t);")
        w("\t\t\tbuildRules = (")
        w("\t\t\t);")
        w("\t\t\tdependencies = (")
        if has_dep:
            w(f"\t\t\t\t{dep} /* PBXTargetDependency */,")
        w("\t\t\t);")
        w(f"\t\t\tname = {tname};")
        w(f"\t\t\tproductName = {tname};")
        w(f"\t\t\tproductReference = {product[0]} /* {product[1]} */;")
        w(f"\t\t\tproductType = \"{ptype}\";")
        w("\t\t};")
    w("/* End PBXNativeTarget section */")
    w("")
    w("/* Begin PBXProject section */")
    w(f"\t\t{project} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w(f'\t\t\tbuildConfigurationList = {u("configlist::project")} /* Build configuration list for PBXProject "OfficeAdminGame" */;')
    w('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group_uuid};")
    w(f"\t\t\tproductRefGroup = {products_group.uuid} /* Products */;")
    w('\t\t\tprojectDirPath = "";')
    w('\t\t\tprojectRoot = "";')
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{app_target} /* {APP_NAME} */,")
    w(f"\t\t\t\t{test_target} /* {TEST_NAME} */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")
    w("")
    w("/* Begin PBXResourcesBuildPhase section */")
    for phase, builds in ((app_res_phase, []), (test_res_phase, test_resource_builds)):
        w(f"\t\t{phase} /* Resources */ = {{")
        w("\t\t\tisa = PBXResourcesBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        for b in builds:
            w(f"\t\t\t\t{b.uuid} /* {b.ref.path} in Resources */,")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")
    w("")
    w("/* Begin PBXSourcesBuildPhase section */")
    for phase, builds in ((app_sources_phase, app_builds), (test_sources_phase, test_source_builds)):
        w(f"\t\t{phase} /* Sources */ = {{")
        w("\t\t\tisa = PBXSourcesBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        for b in builds:
            w(f"\t\t\t\t{b.uuid} /* {b.ref.path} in Sources */,")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")
    w("")
    w("/* Begin PBXTargetDependency section */")
    w(f"\t\t{dep} /* PBXTargetDependency */ = {{")
    w("\t\t\tisa = PBXTargetDependency;")
    w(f"\t\t\ttarget = {app_target} /* {APP_NAME} */;")
    w(f"\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;")
    w("\t\t};")
    w("/* End PBXTargetDependency section */")
    w("")
    w("/* Begin XCBuildConfiguration section */")
    project_common = {
        "ALWAYS_SEARCH_USER_PATHS": False,
        "CLANG_ENABLE_MODULES": True,
        "CLANG_ENABLE_OBJC_ARC": True,
        "COPY_PHASE_STRIP": False,
        "CURRENT_PROJECT_VERSION": 1,
        "DEAD_CODE_STRIPPING": "YES",
        "MARKETING_VERSION": "0.1.0",
        "SDKROOT": "iphoneos",
    }
    L += config_decl("config::project::Debug", "Debug", dict(project_common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": 0,
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    }))
    L += config_decl("config::project::Release", "Release", dict(project_common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
    }))
    app_common = {
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
        "DEVELOPMENT_TEAM": "",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "Shaffer World",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.games",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }
    L += config_decl(f"config::target::{APP_NAME}::Debug", "Debug", app_common)
    L += config_decl(f"config::target::{APP_NAME}::Release", "Release", app_common)
    test_common = {
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
        "DEVELOPMENT_TEAM": "",
        "GENERATE_INFOPLIST_FILE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "TEST_TARGET_NAME": APP_NAME,
    }
    L += config_decl(f"config::target::{TEST_NAME}::Debug", "Debug", test_common)
    L += config_decl(f"config::target::{TEST_NAME}::Release", "Release", test_common)
    w("/* End XCBuildConfiguration section */")
    w("")
    w("/* Begin XCConfigurationList section */")
    for key, label, names in (
        ("configlist::project", 'PBXProject "OfficeAdminGame"', (APP_NAME,)),
        (f"configlist::target::{APP_NAME}", f'PBXNativeTarget "{APP_NAME}"', (APP_NAME,)),
        (f"configlist::target::{TEST_NAME}", f'PBXNativeTarget "{TEST_NAME}"', (TEST_NAME,)),
    ):
        w(f"\t\t{u(key)} /* Build configuration list for {label} */ = {{")
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        for n in ("Debug", "Release"):
            tgt = "project" if key == "configlist::project" else f"target::{names[0]}"
            w(f'\t\t\t\t{u(f"config::{tgt}::{n}")} /* {n} */,')
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")
    w("\t};")
    w(f"\trootObject = {project} /* Project object */;")
    w("}")

    outdir = os.path.join(ROOT, f"{APP_NAME}.xcodeproj")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "project.pbxproj"), "w") as f:
        f.write("\n".join(L) + "\n")

    scheme_dir = os.path.join(outdir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    scheme = SCHEME_TEMPLATE.format(
        app_target=app_target, test_target=test_target,
        app_name=APP_NAME, test_name=TEST_NAME)
    with open(os.path.join(scheme_dir, f"{APP_NAME}.xcscheme"), "w") as f:
        f.write(scheme)

    print(f"wrote {APP_NAME}.xcodeproj ({len(app_sources)} app sources, "
          f"{len(test_sources)} test sources, {len(test_resources)} fixture resources)")


SCHEME_TEMPLATE = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1540"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "{app_name}.app"
               BlueprintName = "{app_name}"
               ReferencedContainer = "container:{app_name}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "{test_name}.xctest"
               BlueprintName = "{test_name}"
               ReferencedContainer = "container:{app_name}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{app_name}.app"
            BlueprintName = "{app_name}"
            ReferencedContainer = "container:{app_name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      launchCustomWorkingDirectory = "NO">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "{app_name}.app"
            BlueprintName = "{app_name}"
            ReferencedContainer = "container:{app_name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''


if __name__ == "__main__":
    sys.exit(main())
