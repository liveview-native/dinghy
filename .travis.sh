#!/bin/bash
set -e
set -x

title() {
    set +x
    echo -e '\n\033[1;33m '$@' \033[0m\n'
    set -x
}


if [ -z "$CARGO_DINGHY" ]
then
    title "••• build cargo-dinghy •••"
    cargo build -p cargo-dinghy
    CARGO_DINGHY="`pwd`/target/debug/cargo-dinghy -vv"
fi
echo RUST_VERSION: ${RUST_VERSION:=1.70.0}

rustup toolchain add $RUST_VERSION
export RUSTUP_TOOLCHAIN=$RUST_VERSION

title "••• test original cargo build •••"
cargo build
cargo test

( \
    cd test-ws/test-app \
    && export NOT_BUILT_WITH_DINGHY=1 \
    && cargo test pass \
    && ! NOT_BUILT_WITH_DINGHY=1 cargo test fails \
)

tests_sequence() {
    title "testing from workspace directory"
    ( \
        cd test-ws \
        && cargo clean \
        && $CARGO_DINGHY -d $1 test pass \
        && ! $CARGO_DINGHY -d $1 test fails \
        && ! $CARGO_DINGHY -d $1 test \
    )

    title "testing from project directory"
    ( \
        cd test-ws/test-app \
        && cargo clean \
        && $CARGO_DINGHY -d $1 test pass \
        && ! $CARGO_DINGHY -d $1 test fails \
        && ! $CARGO_DINGHY -d $1 test \
    )

    title "test from workspace directory with project filter"
    ( \
        cd test-ws \
        && cargo clean \
        && $CARGO_DINGHY -d $1 test -p test-app pass \
        && ! $CARGO_DINGHY -d $1 test -p test-app fails \
        && ! $CARGO_DINGHY -d $1 test -p test-app \
    )
}

tests_sequence_with_runners() {
    title "testing from workspace directory"
    ( \
        cd test-ws \
        && cargo clean \
        &&   cargo +nightly test -Zbuild-std --target $1 pass \
        && ! cargo +nightly test -Zbuild-std --target $1 fails \
        && ! cargo +nightly test -Zbuild-std --target $1 test \
    )

    title "testing from project directory"
    ( \
        cd test-ws/test-app \
        && cargo clean \
        &&   cargo +nightly test -Zbuild-std --target $1 pass \
        && ! cargo +nightly test -Zbuild-std --target $1 fails \
        && ! cargo +nightly test -Zbuild-std --target $1 test \
    )

    title "test from workspace directory with project filter"
    ( \
        cd test-ws \
        && cargo clean \
        &&   cargo +nightly test -p test-app -Zbuild-std --target $1 pass \
        && ! cargo +nightly test -p test-app -Zbuild-std --target $1 fails \
        && ! cargo +nightly test -p test-app -Zbuild-std --target $1 \
    )
}


if [ `uname` = Darwin ]
then
     title "••••• Darwin: ios simulator tests •••••"
     title "boot a simulator"
     rustup target add x86_64-apple-ios;
     RUNTIME_ID=$(xcrun simctl list runtimes | grep iOS | cut -d ' ' -f 7 | tail -1)
     export SIM_ID=$(xcrun simctl create My-iphone8 com.apple.CoreSimulator.SimDeviceType.iPhone-8 $RUNTIME_ID)
     xcrun simctl boot $SIM_ID
     tests_sequence $SIM_ID

     xcrun simctl delete $SIM_ID

    if ios-deploy -c -t 1 > /tmp/ios_devices
    then
        device=$(grep "Found" /tmp/ios_devices | head -1 | cut -d " " -f 3)
        title "••••• Darwin: ios-deploy detected a device •••••"
        rustup target add aarch64-apple-ios
        tests_sequence $device
    fi

     title "••••• Darwin: tvos simulator tests •••••"
     title "boot a simulator"
     rustup toolchain add nightly --components rust-src;
     TVOS_RUNTIME_ID=$(xcrun simctl list runtimes | grep tvOS | cut -d ' ' -f 7 | tail -1)
     export TV_SIM_ID=$(xcrun simctl create My-4ktv com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K $TVOS_RUNTIME_ID)

     xcrun simctl boot $TV_SIM_ID
     tests_sequence_with_runners x86_64-apple-tvos
     xcrun simctl delete $TV_SIM_ID

     title "••••• Darwin: watchvos simulator tests •••••"
     title "boot a simulator"
     rustup toolchain add nightly --components rust-src;
     WATCHOS_RUNTIME_ID=$(xcrun simctl list runtimes | grep watchOS | cut -d ' ' -f 7 | tail -1)
     export WATCHOS_SIM_ID=$(xcrun simctl create My-apple-watch com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-44mm-2nd-generation $WATCHOS_RUNTIME_ID)

     xcrun simctl boot $WATCHOS_SIM_ID
     tests_sequence_with_runners x86_64-apple-watchos-sim
     xcrun simctl delete $WATCHOS_SIM_ID
else
    if [ -n "$ANDROID_SDK_ROOT" ]
    then
        title "••••• Linux: android tests •••••"
        title "setup simulator"
        rustup target add armv7-linux-androideabi

        ## BEGIN FIX-EMULATOR
        # Use emulator version 32.1.15 as latest version (33.1.23 as of writing) from sdk segfaults

        ( \
          cd target/ \
          && wget https://redirector.gvt1.com/edgedl/android/repository/emulator-linux_x64-10696886.zip \
          && unzip emulator-linux_x64-10696886.zip \
        )
        EMULATOR="$(pwd)/target/emulator/emulator"

        # to revert when the bundled emulator doesn't crash anymore use the following line
        # EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"

        # END FIX-EMULATOR

        $ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager --install "system-images;android-24;default;armeabi-v7a" "ndk;22.1.7171670"
        echo no | $ANDROID_SDK_ROOT/cmdline-tools/latest/bin/avdmanager create avd -n testdinghy -k "system-images;android-24;default;armeabi-v7a"
        $EMULATOR @testdinghy -no-audio -no-boot-anim -no-window -accel on -gpu off &
        timeout 180 $ANDROID_SDK_ROOT/platform-tools/adb wait-for-device

        export ANDROID_NDK_HOME=$ANDROID_SDK_ROOT/ndk/22.1.7171670

        tests_sequence android
    fi

    title "••••• Linux: script tests (with qemu) •••••"
    title "setup qemu"

    rustup target add aarch64-unknown-linux-musl
    sudo apt-get update
    sudo apt-get -y install --no-install-recommends qemu-system-arm qemu-user binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu
    echo -e "[platforms.qemu]\nrustc_triple='aarch64-unknown-linux-musl'\ndeb_multiarch='aarch64-linux-gnu'" > .dinghy.toml
    echo -e "[script_devices.qemu]\nplatform='qemu'\npath='/tmp/qemu'" >> .dinghy.toml
    echo -e "#!/bin/sh\nexe=\$1\nshift\n/usr/bin/qemu-aarch64 -L /usr/aarch64-linux-gnu/ \$exe --test-threads 1 \"\$@\"" > /tmp/qemu
    chmod +x /tmp/qemu

    tests_sequence qemu
fi

if [ -n "$DEPLOY" ]
then
    if [ `uname` = Linux ]
    then
        export OPENSSL_STATIC=yes
        export OPENSSL_INCLUDE_DIR=/usr/include
        export OPENSSL_LIB_DIR=$(dirname `find /usr -name libssl.a`)
        cargo clean
    fi
    cargo build --release -p cargo-dinghy
    mkdir -p cargo-dinghy-$DEPLOY
    cp target/release/cargo-dinghy cargo-dinghy-$DEPLOY
    tar vczf cargo-dinghy-$DEPLOY.tgz cargo-dinghy-$DEPLOY
fi
