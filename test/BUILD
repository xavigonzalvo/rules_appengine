load("//appengine:appengine.bzl", "appengine_war")

appengine_war(
    name = "test-war",
    data = [":test-data"],
    data_path = "/test",
    jars = ["libtest.jar"],
)

filegroup(
    name = "test-data",
    srcs = glob(["data/**"]),
)

sh_test(
    name = "check_war",
    srcs = ["check_war.sh"],
    data = [
        ":test-war",
        "@local_jdk//:jar",
        "@local_jdk//:jdk-default",
    ],
)
