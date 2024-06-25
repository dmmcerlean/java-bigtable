#!/bin/bash
# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eo pipefail

## Get the directory of the build script
scriptDir=$(realpath $(dirname "${BASH_SOURCE[0]}"))
## cd to the parent directory, i.e. the root of the git repo
cd ${scriptDir}/..

# include common functions
source ${scriptDir}/common.sh

# Print out Maven & Java version
mvn -version
echo ${JOB_TYPE}

current_java_home=$JAVA_HOME
echo "Current JAVA_HOME: ${current_java_home}"

update-alternatives --list java
update-alternatives --set java /usr/lib/jvm/temurin-17-jdk-amd64/bin/java

CURRENT_PROTO_VERSION=$(mvn -ntp help:effective-pom |
sed -n "/<artifactId>protobuf-java<\/artifactId>/,/<\/dependency>/ {
  /<version>/{
      s/<version>\(.*\)<\/version>/\1/p
      q
  }
}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
echo "The current proto version is: ${CURRENT_PROTO_VERSION}"

LATEST_PROTO_VERSION=$(curl -s https://repo1.maven.org/maven2/com/google/protobuf/protobuf-java/maven-metadata.xml | sed -n '/<release>/s/.*<release>\(.*\)<\/release>.*/\1/p')
echo "The latest proto version is: ${LATEST_PROTO_VERSION}"
LATEST_PROTO_VERSION="3.25.3"

pushd /tmp
git clone https://github.com/googleapis/sdk-platform-java.git
pushd sdk-platform-java
pushd gapic-generator-java-pom-parent
sed -i "/<protobuf.version>.*<\/protobuf.version>/s/\(.*<protobuf.version>\).*\(<\/protobuf.version>\)/\1${LATEST_PROTO_VERSION}\2/" pom.xml
popd
pushd sdk-platform-java-config
SHARED_DEPS_VERSION=$(mvn -ntp help:effective-pom |
sed -n "/<artifactId>sdk-platform-java-config<\/artifactId>/,/<\/dependency>/ {
  /<version>/{
      s/<version>\(.*\)<\/version>/\1/p
      q
  }
}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
echo "Shared-Deps Version: ${SHARED_DEPS_VERSION}"
popd
mvn clean install -q -ntp \
    -DskipTests=true \
    -Dclirr.skip=true \
    -Denforcer.skip=true \
    -T 1C
popd
popd

poms=($(find . -name pom.xml))
for pom in "${poms[@]}"; do
  if grep -q "sdk-platform-java-config" "${pom}"; then
    echo "Updating the pom: ${pom} to use shared-deps version: ${SHARED_DEPS_VERSION}"
    sed -i -E "/<groupId>com.google.cloud<\/groupId>.*<artifactId>sdk-platform-java-config<\/artifactId>/ {
      s/(<version>)[^<]+(<\/version>)/\1${SHARED_DEPS_VERSION}\2/
    }" "${pom}"
  fi
done

# attempt to install 3 times with exponential backoff (starting with 10 seconds)
retry_with_backoff 3 10 \
  mvn install -B -V -ntp \
    -DskipTests=true \
    -Dclirr.skip=true \
    -Denforcer.skip=true \
    -Dmaven.javadoc.skip=true \
    -Dgcloud.download.skip=true \
    -T 1C

# if GOOGLE_APPLICATION_CREDENTIALS is specified as a relative path, prepend Kokoro root directory onto it
if [[ ! -z "${GOOGLE_APPLICATION_CREDENTIALS}" && "${GOOGLE_APPLICATION_CREDENTIALS}" != /* ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS=$(realpath ${KOKORO_GFILE_DIR}/${GOOGLE_APPLICATION_CREDENTIALS})
fi

RETURN_CODE=0
set +e

case ${JOB_TYPE} in
test)
    echo "SUREFIRE_JVM_OPT: ${SUREFIRE_JVM_OPT}"
    mvn test -B -ntp -Dclirr.skip=true -Denforcer.skip=true ${SUREFIRE_JVM_OPT}
    RETURN_CODE=$?
    ;;
lint)
    mvn com.coveo:fmt-maven-plugin:check -B -ntp
    RETURN_CODE=$?
    ;;
javadoc)
    mvn javadoc:javadoc javadoc:test-javadoc -B -ntp
    RETURN_CODE=$?
    ;;
integration)
    mvn -B ${INTEGRATION_TEST_ARGS} \
      -ntp \
      -Penable-integration-tests \
      -DtrimStackTrace=false \
      -Dclirr.skip=true \
      -Denforcer.skip=true \
      -fae \
      verify
    RETURN_CODE=$?
    ;;
graalvm)
    # Run Unit and Integration Tests with Native Image
    mvn -B ${INTEGRATION_TEST_ARGS} -ntp -Pnative test
    RETURN_CODE=$?
    ;;
graalvm17)
    # Run Unit and Integration Tests with Native Image
    mvn -B ${INTEGRATION_TEST_ARGS} -ntp -Pnative test
    RETURN_CODE=$?
    ;;
samples)
    SAMPLES_DIR=samples
    # only run ITs in snapshot/ on presubmit PRs. run ITs in all 3 samples/ subdirectories otherwise.
    if [[ ! -z ${KOKORO_GITHUB_PULL_REQUEST_NUMBER} ]]
    then
      SAMPLES_DIR=samples/snapshot
    fi

    if [[ -f ${SAMPLES_DIR}/pom.xml ]]
    then
        for FILE in ${KOKORO_GFILE_DIR}/secret_manager/*-samples-secrets; do
          [[ -f "$FILE" ]] || continue
          source "$FILE"
        done

        pushd ${SAMPLES_DIR}
        mvn -B \
          -ntp \
          -DtrimStackTrace=false \
          -Dclirr.skip=true \
          -Denforcer.skip=true \
          -fae \
          verify
        RETURN_CODE=$?
        popd
    else
        echo "no sample pom.xml found - skipping sample tests"
    fi
    ;;
clirr)
    mvn -B -ntp -Denforcer.skip=true clirr:check
    RETURN_CODE=$?
    ;;
*)
    ;;
esac

if [ "${REPORT_COVERAGE}" == "true" ]
then
  bash ${KOKORO_GFILE_DIR}/codecov.sh
fi

# fix output location of logs
bash .kokoro/coerce_logs.sh

if [[ "${ENABLE_FLAKYBOT}" == "true" ]]
then
    chmod +x ${KOKORO_GFILE_DIR}/linux_amd64/flakybot
    ${KOKORO_GFILE_DIR}/linux_amd64/flakybot -repo=googleapis/java-bigtable
fi

echo "exiting with ${RETURN_CODE}"
exit ${RETURN_CODE}
