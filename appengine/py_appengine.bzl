# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Python AppEngine support for Bazel.

To create a Python WebApp for Google AppEngine, add the rules:
py_appengine_binary(
  name = "mywebapp",
  # data to put in the webapp, the directory structure of the data set
  # will be maintained.
  data = ["//mywebapp:data"],
  configs = ["//mywebapp:app.yaml", //mywebapp:appengine_config.py],
  srcs = ["main.py"],
)

#optional test
py_appengine_test(
  name = "mywebapp_test",
  srcs = ["main_test.py"],
  deps = [":main"],
  libraries = {"webapp2": "latest"},
)

To run locally:
bazel run :mywebapp

To deploy on Google app engine:
bazel run :mywebapp.deploy -- my-project-id [module.yaml files ...]

Finally, the appengine macro also create a .deploy target that will try to use
the AppEngine SDK to upload your application to AppEngine. It requires the
project ID as the first argument and takes 0 or more module YAML files. If no
YAML files are specified, only "app.yaml", the main module, will be deployed.
"""

load(":variables.bzl", "PY_SDK_SHA256", "PY_SDK_VERSION")
load(":sdk.bzl", "find_locally_or_download")

def py_appengine_repositories(version = PY_SDK_VERSION, sha256 = PY_SDK_SHA256):
    find_locally_or_download(
        name = "com_google_appengine_py",
        lang = "py",
        sha256 = sha256,
        version = version,
        filename_pattern = "google_appengine_{version}.zip",
        strip_prefix_pattern = "google_appengine",
    )

def py_appengine_test(name, srcs, deps = [], data = [], libraries = {}, size = None):
    """A variant of py_test that sets up an App Engine environment."""
    extra_deps = ["@com_google_appengine_py//:appengine"]
    for l in libraries:
        extra_deps.append("@com_google_appengine_py//:{0}-{1}".format(
            l,
            libraries[l],
        ))
    native.py_test(
        name = name,
        deps = deps + extra_deps,
        srcs = srcs,
        data = data,
        size = size,
    )

def _py_appengine_binary_base_impl(ctx):
    """Implementation of the rule that creates

         - the script to run locally
         - the script to deploy
      """

    # TODO(maximermilov): Add support for custom import paths.
    config = ctx.actions.declare_file("appengine_config.py")
    config_content = """
import os
import sys

module_space = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'external')

repo_dirs = [os.path.join(module_space, d) for d in os.listdir(module_space)]
sys.path.extend([d for d in repo_dirs if os.path.isdir(d)])
"""
    symlinks = {
        "appengine_config.py": config,
    }

    appengine_config = None
    configs = ""

    for c in ctx.attr.configs:
        files = c.files.to_list()
        for f in files:
            if f.basename == "appengine_config.py":
                appengine_config = f
            elif f.extension == "yaml":
                # Symlink YAML config files to the top-level directory.
                symlinks[f.basename] = f
                configs += " \"" + f.basename + "\""
            else:
                # Fail if any .py files were provided that were not appengine_configs.
                fail("Invalid config file provided: " + f.short_path)

    if ctx.attr.overwrite_appengine_config and appengine_config:
        ctx.actions.run_shell(
            inputs = [appengine_config],
            outputs = [config],
            command = "cp %s %s" % (appengine_config.path, config.path),
        )
    else:
        if appengine_config:
            # Symlink the user-provided appengine_config file(s) to avoid name
            # collisions and add import(s) from the custom appengine_config being
            # created.
            new_path = f.short_path.replace(
                "appengine_config",
                "real_appengine_config",
            )
            symlinks[new_path] = f

            import_path = new_path.rsplit(".", 1)[0].replace("/", ".")
            config_content += "\nimport {}\n".format(import_path)

        ctx.actions.write(
            output = config,
            content = config_content,
        )

    runfiles = ctx.runfiles(
        transitive_files = ctx.attr.devappserver.data_runfiles.files,
        symlinks = symlinks,
    ).merge(ctx.attr.binary.data_runfiles).merge(ctx.attr.appcfg.data_runfiles)

    substitutions = {
        "%{appcfg}": ctx.attr.appcfg.files_to_run.executable.short_path,
        "%{devappserver}": ctx.attr.devappserver.files_to_run.executable.short_path,
        "%{gcloud_path}": ctx.attr.gcloud.files_to_run.executable.short_path,
        "%{workspace_name}": ctx.workspace_name,
        "%{configs}": configs,
    }

    ctx.actions.expand_template(
        output = ctx.outputs.executable,
        template = ctx.file._runner_template,
        substitutions = substitutions,
        is_executable = True,
    )

    ctx.actions.expand_template(
        output = ctx.outputs.deploy_sh,
        template = ctx.file._deploy_template,
        substitutions = substitutions,
        is_executable = True,
    )

    return [DefaultInfo(runfiles = runfiles), ctx.attr.binary[PyInfo]]

py_appengine_binary_base = rule(
    _py_appengine_binary_base_impl,
    attrs = {
        "binary": attr.label(),
        "devappserver": attr.label(
            default = Label("@com_google_appengine_py//:dev_appserver"),
        ),
        "appcfg": attr.label(default = Label("@com_google_appengine_py//:appcfg")),
        "gcloud": attr.label(default = Label("@com_google_cloud_sdk//:gcloud")),
        "configs": attr.label_list(allow_files = [".yaml", ".py"]),
        "overwrite_appengine_config": attr.bool(
            doc = """"If true, patch the user's appengine_config into the base one. If false, use
                      the user specified config directly.""",
            default = True,
        ),
        "_deploy_template": attr.label(
            default = Label("//appengine/py:deploy_template"),
            allow_single_file = True,
        ),
        "_runner_template": attr.label(
            default = Label("//appengine/py:runner_template"),
            allow_single_file = True,
        ),
    },
    executable = True,
    outputs = {
        "deploy_sh": "%{name}_deploy.sh",
    },
)

def py_appengine_binary(name, srcs, configs, deps = [], data = [], overwrite_appengine_config = True, python_version = "PY3"):
    """Convenience macro that builds the app and offers an executable

         target to deploy on Google app engine.
      """
    if not srcs:
        fail("srcs should not be empty.")

    # uses py_binary because it generates __init__.py files
    native.py_binary(
        name = "_py_appengine_" + name,
        srcs = srcs,
        deps = deps,
        data = data,
        python_version = python_version,
        main = srcs[0],  # no entry point, use arbitrary source file
    )
    py_appengine_binary_base(
        name = name,
        binary = ":_py_appengine_" + name,
        configs = configs,
        overwrite_appengine_config = overwrite_appengine_config,
    )
    native.sh_binary(
        name = "%s.deploy" % name,
        srcs = ["%s_deploy.sh" % name],
        data = [
            name,
            "@com_google_cloud_sdk//:gcloud",
        ],
    )

def py_appengine_library(**kwargs):
    """Wrapper for py_library

      """
    native.py_library(**kwargs)
