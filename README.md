# VoiceInk (Fork)

This is a fork of the original [VoiceInk](https://github.com/Beingpax/VoiceInk) project by [Beingpax](https://github.com/Beingpax).

## Purpose of this Fork

This fork primarily implements specific modifications to the Push-to-Talk (PTT) functionality:

*   **Multi-Key Push-To-Talk:** Allows using multiple keys simultaneously for PTT activation (e.g., Fn + Right Cmd).
*   **Enhanced PTT Behavior:**
    *   **Click (Short Press):** Dismisses the recorder window.
    *   **Hold (Long Press):** Records while keys are held, stops on release (original behavior).
    *   **Double-Click:** Toggles recording on/off. Subsequent clicks stop the recording if it's active.
*   **No Shortcut Dependency:** Push-to-Talk can be used independently without needing the main global keyboard shortcut configured.

## Support the Original Project

VoiceInk is an excellent open-source project. If you find it useful, please consider supporting the original developer by purchasing a license at [tryvoiceink.com](https://tryvoiceink.com). This helps fund the continued development of the main project.

## Goals & Contributions

The goal of this fork is to maintain these specific PTT features while staying relatively current with the upstream `Beingpax/VoiceInk` repository.

We welcome contributions related to these PTT features or general maintenance of the fork. However, **please open an issue first** to discuss any proposed changes or pull requests before starting work. This ensures alignment and avoids duplicated effort.

For building instructions and general information about VoiceInk, please refer to the original project's documentation.
