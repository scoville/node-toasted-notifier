# https://gyp.gsrc.io/docs/UserDocumentation.md
# https://gyp.gsrc.io/docs/InputFormatReference.md
{
  'targets': [
    {
      'target_name': 'notifier',
      'dependencies': [
        "<!(node -p \"require('node-addon-api').targets\"):node_addon_api_except",
      ],
      'cflags_cc': ['-std=c++20'],
      'conditions': [
        [
            'OS=="mac"',
            # https://github.com/nodejs/node-addon-api/blob/294a43f8c6a4c79b3295a8f1b83d4782d44cfe74/doc/setup.md
            {
                'cflags+': ['-fvisibility=hidden'],
                'sources': ['node-api/notifier_macos.mm'],
                'xcode_settings': {
                  'OTHER_CFLAGS': ['-mmacos-version-min=10.15', '-std=c++20'],
                  'OTHER_LDFLAGS': ['-framework AuthenticationServices', '-framework UserNotifications'],
                    'GCC_GENERATE_DEBUGGING_SYMBOLS': 'YES',
                    'GCC_SYMBOLS_PRIVATE_EXTERN': 'YES', # -fvisibility=hidden
                    'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym',
                },
            },
            'OS=="win"',
            {
                'sources': ['node-api/notifier_windows.cpp'],
            },
            {
                'sources': ['node-api/notifier_other.cpp'],
            }
        ]
      ],
    },
  ],
}
