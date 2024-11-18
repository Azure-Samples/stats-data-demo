commands=("az")

for cmd in "${commands[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd command is not available, check pre-requisites in README.md"
    exit 1
  fi
done

# Load Test API Constants
ApiVersion='2024-07-01-preview'
LoadTestingTokenScope='https://cnt-prod.loadtesting.azure.com'

# Function App Details
FunctionAppName="${AZURE_FUNCTION_NAME}"
FunctionAppTriggerName="${AZURE_FUNCTION_APP_TRIGGER_NAME}"
FunctionAppResourceId="${AZURE_FUNCTION_APP_RESOURCE_ID}"

# ALT Resource Details
LoadTestResourceId="${AZURE_LOADTEST_RESOURCE_ID}"
LoadTestResourceName="${AZURE_LOADTEST_RESOURCE_NAME}"
ResourceGroupName="${RESOURCE_GROUP}"
TestId="${LOADTEST_TEST_ID}"
DataPlaneURL="https://${LOADTEST_DP_URL//\"/}"
TestProfileId="${LOADTEST_PROFILE_ID}"
TestFileName='url-test.json'
FunctionAppComponentType='microsoft.web/sites'

# Load Test Configuration
EngineInstances=1
TestDurationInSec=60
VirtualUsers=25
RampUpTime=0
LoadTestDisplayName="Test_$(date +%Y%m%d%H%M%S)"
TestProfileDisplayName="TestProfile_$(date +%Y%m%d%H%M%S)"
TestProfileRunDisplayName="TestProfileRun_$(date +%Y%m%d%H%M%S)"
TestProfileDescription=''

# Function to run az cli command and handle errors
run_az_cli_command() {
    local command="$1"
    local suppress_output="$2"
    if [ "$suppress_output" = true ]; then
        eval "$command > /dev/null 2>&1"
    else
        eval "$command"
    fi
    if [ $? -ne 0 ]; then
        echo "Error: Failed to execute command: $command"
        exit 1
    fi
}

# Function to get the default function key
get_function_default_key() {
    local function_app_name="$1"
    local function_app_trigger_name="$2"
    local key
    key=$(run_az_cli_command "az functionapp function keys list -g $ResourceGroupName -n $function_app_name --function-name $function_app_trigger_name --query default" true)
    echo "${key//\"/}"
}

# Function to get URL test configuration
get_url_test_config() {
    local function_name="$1"
    local trigger_name="$2"
    local virtual_users="$3"
    local duration_in_seconds="$4"
    local ramp_up_time="$5"
    local function_trigger_key
    function_trigger_key=$(get_function_default_key "$function_name" "$trigger_name")

    cat <<EOF
{
    "version": "1.0",
    "scenarios": {
        "requestGroup1": {
            "requests": [
                {
                    "requestName": "Request1",
                    "queryParameters": [],
                    "requestType": "URL",
                    "endpoint": "https://$function_name.azurewebsites.net/api/$trigger_name",
                    "headers": {
                        "x-functions-key": "$function_trigger_key"
                    },
                    "method": "POST",
                    "body": "playerID,birthYear,birthMonth,birthDay,birthCountry,birthState,birthCity,deathYear,deathMonth,deathDay,deathCountry,deathState,deathCity,nameFirst,nameLast,nameGiven,weight,height,bats,throws,debut,finalGame,retroID,bbrefID\naardsda01,1981,12,27,USA,CO,Denver,,,,,,,David,Aardsma,David Allan,220,75,R,R,2004-04-06,2015-08-23,aardd001,aardsda01",
                    "requestBodyFormat": "Text",
                    "responseVariables": []
                }
            ],
            "csvDataSetConfigList": []
        }
    },
    "testSetup": [
        {
            "virtualUsersPerEngine": $virtual_users,
            "durationInSeconds": $duration_in_seconds,
            "loadType": "Linear",
            "scenario": "requestGroup1",
            "rampUpTimeInSeconds": $ramp_up_time
        }
    ]
}
EOF
}

# Function to call Azure Load Testing
call_azure_load_testing() {
    local url="$1"
    local method="$2"
    local body="$3"
    local content_type='application/json'
    if [ "$method" = "PATCH" ]; then
        content_type='application/merge-patch+json'
    fi
    local access_token
    access_token=$(get_load_testing_access_token)
    if [ "$method" != "GET" ]; then
        curl -X "$method" -H "Authorization: Bearer $access_token" -H "Content-Type: $content_type" -d "$body" "$url"
    else
        curl -X "$method" -H "Authorization: Bearer $access_token" -H "Content-Type: $content_type" "$url"
    fi
}

# Function to upload test file
upload_test_file() {
    local url="$1"
    local file_content="$2"
    local wait_for_completion="$3"
    local access_token
    access_token=$(get_load_testing_access_token)
    local content
    content=$(echo -n "$file_content" | base64)
    local resp
    resp=$(curl -X PUT -H "Authorization: Bearer $access_token" -H "Content-Type: application/octet-stream" --data "$content" "$url")
    echo "Upload Status: $(echo "$resp" | jq -r '.validationStatus')"
    local poll_count=0
    if [ "$wait_for_completion" = true ]; then
        while [ "$(echo "$resp" | jq -r '.validationStatus')" != "VALIDATION_SUCCESS" ] && [ "$(echo "$resp" | jq -r '.validationStatus')" != "VALIDATION_FAILURE" ]; do
            if [ $poll_count -gt 10 ]; then
                echo "Polling count exceeded 10, exiting"
                exit 1
            fi
            sleep 10
            resp=$(curl -X GET -H "Authorization: Bearer $access_token" "$url")
            echo "Current Validation Status: $(echo "$resp" | jq -r '.validationStatus'), PollCount: $poll_count"
            poll_count=$((poll_count + 1))
        done
    fi
    echo "$resp"
}

# Function to get load testing access token
get_load_testing_access_token() {
    local access_token
    access_token=$(run_az_cli_command "az account get-access-token --resource $LoadTestingTokenScope --query accessToken" true)
    echo "${access_token//\"/}"
}

# Function to poll test profile run
poll_test_profile_run() {
    local test_profile_run_url="$1"
    local access_token
    access_token=$(get_load_testing_access_token)
    local resp
    resp=$(curl -X GET -H "Authorization: Bearer $access_token" "$test_profile_run_url")
    echo "Current Status: $(echo "$resp" | jq -r '.status')"
    local poll_count=0
    while [ "$(echo "$resp" | jq -r '.status')" != "DONE" ] && [ "$(echo "$resp" | jq -r '.status')" != "FAILED" ] && [ "$(echo "$resp" | jq -r '.status')" != "STOPPED" ]; do
        if [ $poll_count -gt 150 ]; then
            echo "Polling count exceeded 150, exiting"
            exit 1
        fi
        sleep 20
        resp=$(curl -X GET -H "Authorization: Bearer $access_token" "$test_profile_run_url")
        echo "Current Status: $(echo "$resp" | jq -r '.status'), PollCount: $poll_count"
        poll_count=$((poll_count + 1))
    done
}

# Function to add app component metrics
add_app_component_metrics() {
    local metric_name="$1"
    local aggregation="$2"
    local metric_id="$FunctionAppResourceId/providers/microsoft.insights/metricdefinitions/$metric_name"
    run_az_cli_command "az load test server-metric add --test-id $TestId --load-test-resource $LoadTestResourceName --resource-group $ResourceGroupName --metric-id $metric_id --metric-name $metric_name --metric-namespace $FunctionAppComponentType --aggregation $aggregation --app-component-type $FunctionAppComponentType --app-component-id $FunctionAppResourceId"
}

# Function to create test profile
create_test_profile() {
    local test_profile_display_name="$1"
    local test_profile_description="$2"
    local test_id="$3"
    local function_app_resource_id="$4"
    local data_plane_url="$5"
    local test_profile_id="$6"
    local api_version="$7"
    local test_profile_request
    test_profile_request=$(cat <<EOF
{
    "displayName": "$test_profile_display_name",
    "description": "$test_profile_description",
    "testId": "$test_id",
    "targetResourceId": "$function_app_resource_id",
    "targetResourceConfigurations": {
        "kind": "FunctionsFlexConsumption",
        "configurations": {
            "config1": {
                "instanceMemoryMB": "2048",
                "httpConcurrency": 1
            },
            "config2": {
                "instanceMemoryMB": "2048",
                "httpConcurrency": 10
            },
            "config3": {
                "instanceMemoryMB": "2048",
                "httpConcurrency": 50
            }
        }
    }
}
EOF
)
    call_azure_load_testing "$data_plane_url/test-profiles/$test_profile_id?api-version=$api_version" "PATCH" "$test_profile_request"
    echo "Successfully created the test profile"
}

# Function to create and configure load test
create_and_configure_load_test() {
    local test_id="$1"
    local load_test_resource_name="$2"
    local resource_group_name="$3"
    local load_test_display_name="$4"
    local engine_instances="$5"
    local function_app_name="$6"
    local function_app_component_type="$7"
    local function_app_resource_id="$8"
    local virtual_users="$9"
    local test_duration_in_sec="${10}"
    local ramp_up_time="${11}"
    local data_plane_url="${12}"
    local test_file_name="${13}"
    local api_version="${14}"
    echo "Creating test with testId: $test_id"
    if az load test show --name "$load_test_resource_name" --test-id "$test_id" --resource-group "$resource_group_name"; then
        echo "Test with ID: $test_id already exists"
        run_az_cli_command "az load test update --name $load_test_resource_name --test-id $test_id --display-name $load_test_display_name --resource-group $resource_group_name --engine-instances $engine_instances"
    else
        echo "Test with ID: $test_id does not exist. Creating a new test"
        run_az_cli_command "az load test create --name $load_test_resource_name --test-id $test_id --display-name $load_test_display_name --resource-group $resource_group_name --engine-instances $engine_instances"
    fi
    echo "Successfully created load test $test_id in the Azure Load Testing Resource $load_test_resource_name"

    # Configure App Components and metrics
    echo "Configuring app component and metrics"
    run_az_cli_command "az load test app-component add --test-id $test_id --load-test-resource $load_test_resource_name --resource-group $resource_group_name --app-component-name $function_app_name --app-component-type $function_app_component_type --app-component-id $function_app_resource_id --app-component-kind 'function'"
    add_app_component_metrics "OnDemandFunctionExecutionCount" "Total"
    add_app_component_metrics "AlwaysReadyFunctionExecutionCount" "Total"
    add_app_component_metrics "OnDemandFunctionExecutionUnits" "Average"
    add_app_component_metrics "AlwaysReadyFunctionExecutionUnits" "Average"
    add_app_component_metrics "AlwaysReadyUnits" "Average"

    # Upload Test Plan
    echo "Upload test plan to test with testId: $test_id"
    local test_plan
    test_plan=$(get_url_test_config "$function_app_name" "$function_app_trigger_name" "$virtual_users" "$test_duration_in_sec" "$ramp_up_time")
    local test_plan_upload_url
    test_plan_upload_url="$data_plane_url/tests/$test_id/files/$test_file_name?api-version=$api_version&fileType=URL_TEST_CONFIG"
    upload_test_file "$test_plan_upload_url" "$test_plan" true
    echo "Successfully uploaded the test plan to the test"
}

create_test_profile_run() {
    local test_profile_id="$1"
    local test_profile_run_display_name="$2"
    local data_plane_url="$3"
    local api_version="$4"

    local test_profile_run_request=$(cat <<EOF
{
    "testProfileId": "$test_profile_id",
    "displayName": "$test_profile_run_display_name"
}
EOF
)

    local test_profile_run_id
    test_profile_run_id=$(uuidgen | tr A-Z a-z) // Generate a unique ID for the test profile run with lowercase characters
    local test_profile_run_url="$data_plane_url/test-profile-runs/$test_profile_run_id?api-version=$api_version"

    log "Creating TestProfileRun with ID: $test_profile_run_id"

    if call_azure_load_testing "$test_profile_run_url" "PATCH" "$test_profile_run_request"; then
        echo -e "Successfully created the test profile run"
    else
        echo -e "Error: Failed to create test profile run $test_profile_run_id"
        exit 1
    fi

    # local encoded_function_resource_id
    # encoded_function_resource_id=$(url_encode_with_capital_hex "$FunctionAppResourceId")
    # local encoded_alt_resource_id
    # encoded_alt_resource_id=$(url_encode_with_capital_hex "$LoadTestResourceId")

    # local perf_optimizer_url="https://portal.azure.com/#view/Microsoft_Azure_CloudNativeTesting/TestProfileRun/resourceId/$encoded_alt_resource_id/testProfileId/$test_profile_id/openingFromBlade~/true/sourceResourceId/$encoded_function_resource_id"
    # echo "Performance Optimizer URL - $perf_optimizer_url"

    # # Uncomment the following line to poll the test profile run
    # poll_test_profile_run "$test_profile_run_url"
}


# Ensure az load extension is installed
az extension add --name load

# Create and configure test
create_and_configure_load_test "$TestId" "$LoadTestResourceName" "$ResourceGroupName" "$LoadTestDisplayName" "$EngineInstances" "$FunctionAppName" "$FunctionAppComponentType" "$FunctionAppResourceId" "$VirtualUsers" "$TestDurationInSec" "$RampUpTime" "$DataPlaneURL" "$TestFileName" "$ApiVersion"

# Create Test Profile
create_test_profile "$TestProfileDisplayName" "$TestProfileDescription" "$TestId" "$FunctionAppResourceId" "$DataPlaneURL" "$TestProfileId" "$ApiVersion"

# Create Test Profile Run
create_test_profile_run "$TestProfileId" "$TestProfileRunDisplayName" "$DataPlaneURL" "$ApiVersion"

# Uncomment the following line to poll the test profile run
# poll_test_profile_run "$TestProfileRunURL"