// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IOperatorFilterRegistry} from "./IOperatorFilterRegistry.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {OperatorFilterRegistryErrorsAndEvents} from "./OperatorFilterRegistryErrorsAndEvents.sol";

/**
 * @title  OperatorFilterRegistry
 * @notice Borrows heavily from the QQL BlacklistOperatorFilter contract:
 *         https://github.com/qql-art/contracts/blob/main/contracts/BlacklistOperatorFilter.sol
 * @notice This contracts allows tokens or token owners to register specific addresses or codeHashes that may be
 * *       restricted according to the isOperatorAllowed function.
 */
contract OperatorFilterRegistry is IOperatorFilterRegistry, OperatorFilterRegistryErrorsAndEvents {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    struct Registration {
        bool isRegistered;
        address subscription;
    }

    mapping(address => EnumerableSet.AddressSet) private _filteredOperators;
    mapping(address => EnumerableSet.Bytes32Set) private _filteredCodeHashes;
    mapping(address => Registration) private _registrations;
    mapping(address => EnumerableSet.AddressSet) private _subscribers;

    /**
     * @notice restricts method caller to the address or EIP-173 "owner()"
     */
    modifier onlyAddressOrOwner(address addr) {
        if (msg.sender != addr) {
            try Ownable(addr).owner() returns (address owner) {
                if (msg.sender != owner) {
                    revert OnlyAddressOrOwner();
                }
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert NotOwnable();
                } else {
                    /// @solidity memory-safe-assembly
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        }
        _;
    }

    /**
     * @notice Returns true if operator is not filtered for a given token, either by address or codeHash. Also returns
     *         true if addr is not registered.
     */
    function isOperatorAllowed(address registrant, address operator) external view returns (bool) {
        Registration memory registration = _registrations[registrant];
        if (registration.isRegistered) {
            EnumerableSet.AddressSet storage filteredOperatorsRef;
            EnumerableSet.Bytes32Set storage filteredCodeHashesRef;
            address subscription = registration.subscription;
            if (subscription == address(0)) {
                filteredOperatorsRef = _filteredOperators[registrant];
                filteredCodeHashesRef = _filteredCodeHashes[registrant];
            } else {
                filteredOperatorsRef = _filteredOperators[subscription];
                filteredCodeHashesRef = _filteredCodeHashes[subscription];
            }

            if (filteredOperatorsRef.contains(operator)) {
                revert AddressFiltered(operator);
            }
            if (operator.code.length > 0) {
                bytes32 codeHash = operator.codehash;
                if (filteredCodeHashesRef.contains(codeHash)) {
                    revert CodeHashFiltered(operator, codeHash);
                }
            }
        }
        return true;
    }

    //////////////////
    // AUTH METHODS //
    //////////////////

    /**
     * @notice Registers an address with the registry. May be called by address itself or by EIP-173 owner.
     */
    function register(address registrant) external onlyAddressOrOwner(registrant) {
        if (_registrations[registrant].isRegistered) {
            revert AlreadyRegistered();
        }
        _registrations[registrant].isRegistered = true;
        emit RegistrationUpdated(registrant, true);
    }

    /**
     * @notice Unregisters an address with the registry and removes its subscription. May be called by address itself or by EIP-173 owner.
     *         Note that this does not remove any filtered addresses or codeHashes.
     */
    function unregister(address registrant) external onlyAddressOrOwner(registrant) {
        Registration memory registration = _registrations[registrant];
        if (!registration.isRegistered) {
            revert NotRegistered(registrant);
        }
        address subscription = registration.subscription;
        if (subscription != address(0)) {
            _subscribers[subscription].remove(registrant);
            emit SubscriptionUpdated(registrant, subscription, false);
        }
        _registrations[registrant].isRegistered = false;
        _registrations[registrant].subscription = address(0);
        emit RegistrationUpdated(registrant, false);
    }

    /**
     * @notice Registers an address with the registry and "subscribes" to another address's filtered operators and codeHashes.
     */
    function registerAndSubscribe(address registrant, address subscription) external onlyAddressOrOwner(registrant) {
        Registration memory registration = _registrations[registrant];
        if (registration.isRegistered) {
            revert AlreadyRegistered();
        }
        if (registrant == subscription) {
            revert CannotSubscribeToSelf();
        }
        Registration memory subscriptionRegistration = _registrations[subscription];
        if (!subscriptionRegistration.isRegistered) {
            revert NotRegistered(subscription);
        }
        if (subscriptionRegistration.subscription != address(0)) {
            revert CannotSubscribeToRegistrantWithSubscription(subscription);
        }
        registration.isRegistered = true;
        registration.subscription = subscription;
        _registrations[registrant] = registration;
        _subscribers[subscription].add(registrant);
        emit RegistrationUpdated(registrant, true);
        emit SubscriptionUpdated(registrant, subscription, true);
    }

    /**
     * @notice Registers an address with the registry and copies the filtered operators and codeHashes from another
     *         address without subscribing.
     */
    function registerAndCopyEntries(address registrant, address registrantToCopy)
        external
        onlyAddressOrOwner(registrant)
    {
        Registration memory registration = _registrations[registrant];
        if (registration.isRegistered) {
            revert AlreadyRegistered();
        }
        Registration memory registrantRegistration = _registrations[registrantToCopy];
        if (!registrantRegistration.isRegistered) {
            revert NotRegistered(registrantToCopy);
        }
        registration.isRegistered = true;
        emit RegistrationUpdated(registrant, true);
        _copyEntries(registrant, registrantToCopy);
    }

    /**
     * @notice Update an operator address for a registered address - when filtered is true, the operator is filtered.
     */
    function updateOperator(address registrant, address operator, bool filtered)
        external
        onlyAddressOrOwner(registrant)
    {
        Registration memory registration = _registrations[registrant];
        if (!registration.isRegistered) {
            revert NotRegistered(registrant);
        }
        if (registration.subscription != address(0)) {
            revert CannotUpdateWhileSubscribed(registration.subscription);
        }
        EnumerableSet.AddressSet storage filteredOperatorsRef = _filteredOperators[registrant];

        if (!filtered) {
            bool removed = filteredOperatorsRef.remove(operator);
            if (!removed) {
                revert AddressNotFiltered(operator);
            }
        } else {
            bool added = filteredOperatorsRef.add(operator);
            if (!added) {
                revert AddressAlreadyFiltered(operator);
            }
        }
        emit OperatorUpdated(registrant, operator, filtered);
    }

    /**
     * @notice Update a codeHash for a registered address - when filtered is true, the codeHash is filtered.
     */
    function updateCodeHash(address registrant, bytes32 codeHash, bool filtered)
        external
        onlyAddressOrOwner(registrant)
    {
        if (codeHash == bytes32(0)) {
            revert CannotFilterZeroCodeHash();
        }
        Registration memory registration = _registrations[registrant];
        if (!registration.isRegistered) {
            revert NotRegistered(registrant);
        }
        if (registration.subscription != address(0)) {
            revert CannotUpdateWhileSubscribed(registration.subscription);
        }
        EnumerableSet.Bytes32Set storage filteredCodeHashesRef = _filteredCodeHashes[registrant];

        if (!filtered) {
            bool removed = filteredCodeHashesRef.remove(codeHash);
            if (!removed) {
                revert CodeHashNotFiltered(codeHash);
            }
        } else {
            bool added = filteredCodeHashesRef.add(codeHash);
            if (!added) {
                revert CodeHashAlreadyFiltered(codeHash);
            }
        }
        emit CodeHashUpdated(registrant, codeHash, filtered);
    }

    /**
     * @notice Update a multiple operators for a registered address - when filtered is true, the operators will be filtered. Reverts on duplicates.
     */
    function updateOperators(address registrant, address[] calldata operators, bool filtered)
        external
        onlyAddressOrOwner(registrant)
    {
        Registration memory registration = _registrations[registrant];
        if (!registration.isRegistered) {
            revert NotRegistered(registrant);
        }
        if (registration.subscription != address(0)) {
            revert CannotUpdateWhileSubscribed(registration.subscription);
        }
        EnumerableSet.AddressSet storage filteredOperatorsRef = _filteredOperators[registrant];
        uint256 operatorsLength = operators.length;
        unchecked {
            if (!filtered) {
                for (uint256 i = 0; i < operatorsLength; ++i) {
                    address operator = operators[i];
                    bool removed = filteredOperatorsRef.remove(operators[i]);
                    if (!removed) {
                        revert AddressNotFiltered(operators[i]);
                    }
                    emit OperatorUpdated(registrant, operator, false);
                }
            } else {
                for (uint256 i = 0; i < operatorsLength; ++i) {
                    address operator = operators[i];
                    bool added = filteredOperatorsRef.add(operator);
                    if (!added) {
                        revert AddressAlreadyFiltered(operator);
                    }
                    emit OperatorUpdated(registrant, operator, true);
                }
            }
        }
    }

    /**
     * @notice Update a multiple codeHashes for a registered address - when filtered is true, the codeHashes will be filtered. Reverts on duplicates.
     */
    function updateCodeHashes(address registrant, bytes32[] calldata codeHashes, bool filtered)
        external
        onlyAddressOrOwner(registrant)
    {
        Registration memory registration = _registrations[registrant];
        if (!registration.isRegistered) {
            revert NotRegistered(registrant);
        }
        if (registration.subscription != address(0)) {
            revert CannotUpdateWhileSubscribed(registration.subscription);
        }
        EnumerableSet.Bytes32Set storage filteredCodeHashesRef = _filteredCodeHashes[registrant];
        uint256 codeHashesLength = codeHashes.length;
        unchecked {
            if (!filtered) {
                for (uint256 i = 0; i < codeHashesLength; ++i) {
                    bytes32 codeHash = codeHashes[i];
                    bool removed = filteredCodeHashesRef.remove(codeHash);
                    if (!removed) {
                        revert CodeHashNotFiltered(codeHash);
                    }
                    emit CodeHashUpdated(registrant, codeHash, false);
                }
            } else {
                for (uint256 i = 0; i < codeHashesLength; ++i) {
                    bytes32 codeHash = codeHashes[i];
                    bool added = filteredCodeHashesRef.add(codeHash);
                    if (!added) {
                        revert CodeHashAlreadyFiltered(codeHash);
                    }
                    emit CodeHashUpdated(registrant, codeHash, true);
                }
            }
        }
    }

    /**
     * @notice Subscribe an address to another registrant's filtered operators and codeHashes. Will remove previous
     *         subscription if present.
     */
    function subscribe(address registrant, address newSubscription) external onlyAddressOrOwner(registrant) {
        if (registrant == newSubscription) {
            revert CannotSubscribeToSelf();
        }
        if (newSubscription == address(0)) {
            revert CannotSubscribeToZeroAddress();
        }
        Registration memory registration = _registrations[registrant];
        if (!registration.isRegistered) {
            revert NotRegistered(registrant);
        }
        if (registration.subscription == newSubscription) {
            revert AlreadySubscribed(newSubscription);
        }
        Registration memory newSubscriptionRegistration = _registrations[newSubscription];
        if (!newSubscriptionRegistration.isRegistered) {
            revert NotRegistered(newSubscription);
        }
        if (newSubscriptionRegistration.subscription != address(0)) {
            revert CannotSubscribeToRegistrantWithSubscription(newSubscription);
        }

        if (registration.subscription != address(0)) {
            _subscribers[registration.subscription].remove(registrant);
            emit SubscriptionUpdated(registrant, registration.subscription, false);
        }
        registration.subscription = newSubscription;
        _registrations[registrant] = registration;
        _subscribers[newSubscription].add(registrant);
        emit SubscriptionUpdated(registrant, newSubscription, true);
    }

    /**
     * @notice Unsubscribe an address from its current subscribed registrant, and optionally copy its filtered operators and codeHashes.
     */
    function unsubscribe(address registrant, bool copyExistingEntries)
        external
        onlyAddressOrOwner(registrant)
        returns (address formerSubscription)
    {
        Registration memory registration = _registrations[registrant];
        if (!registration.isRegistered) {
            revert NotRegistered(registrant);
        }
        if (registration.subscription == address(0)) {
            revert NotSubscribed();
        }
        formerSubscription = registration.subscription;
        _subscribers[formerSubscription].remove(registrant);
        registration.subscription = address(0);
        _registrations[registrant] = registration;
        emit SubscriptionUpdated(registrant, formerSubscription, false);
        if (copyExistingEntries) {
            _copyEntries(registrant, formerSubscription);
        }
    }

    /**
     * @notice Copy filtered operators and codeHashes from a different registrant to addr.
     */
    function copyEntriesOf(address registrant, address registrantToCopy) external onlyAddressOrOwner(registrant) {
        Registration memory registration = _registrations[registrant];
        if (!registration.isRegistered) {
            revert NotRegistered(registrant);
        }
        if (registration.subscription != address(0)) {
            revert CannotUpdateWhileSubscribed(registration.subscription);
        }
        Registration memory registrantRegistration = _registrations[registrantToCopy];
        if (!registrantRegistration.isRegistered) {
            revert NotRegistered(registrantToCopy);
        }
        _copyEntries(registrant, registrantToCopy);
    }

    /// @dev helper to copy entries from registrant to addr and emit events
    function _copyEntries(address registrant, address registrantToCopy) private {
        EnumerableSet.AddressSet storage filteredOperatorsRef = _filteredOperators[registrantToCopy];
        EnumerableSet.Bytes32Set storage filteredCodeHashesRef = _filteredCodeHashes[registrantToCopy];
        uint256 filteredOperatorsLength = filteredOperatorsRef.length();
        uint256 filteredCodeHashesLength = filteredCodeHashesRef.length();
        unchecked {
            for (uint256 i = 0; i < filteredOperatorsLength; ++i) {
                address operator = filteredOperatorsRef.at(i);
                bool added = _filteredOperators[registrant].add(operator);
                if (added) {
                    emit OperatorUpdated(registrant, operator, true);
                }
            }
            for (uint256 i = 0; i < filteredCodeHashesLength; ++i) {
                bytes32 codehash = filteredCodeHashesRef.at(i);
                bool added = _filteredCodeHashes[registrant].add(codehash);
                if (added) {
                    emit CodeHashUpdated(registrant, codehash, true);
                }
            }
        }
    }

    //////////////////
    // VIEW METHODS //
    //////////////////

    /**
     * @notice Get the subscription address of a given address, if any.
     */
    function subscriptionOf(address addr) external view returns (address subscription) {
        return _registrations[addr].subscription;
    }

    /**
     * @notice Get the list of addresses subscribed to a given registrant.
     */
    function subscribers(address addr) external view returns (address[] memory) {
        return _subscribers[addr].values();
    }

    /**
     * @notice Get the subscriber at a given index in the list of addresses subscribed to a given registrant.
     */
    function subscriberAt(address registrant, uint256 index) external view returns (address) {
        return _subscribers[registrant].at(index);
    }

    /**
     * @notice Returns true if operator is filtered by a given address or its subscription.
     */
    function isOperatorFiltered(address registrant, address operator) external view returns (bool) {
        Registration memory registration = _registrations[registrant];
        if (registration.subscription != address(0)) {
            return _filteredOperators[registration.subscription].contains(operator);
        }
        return _filteredOperators[registrant].contains(operator);
    }

    /**
     * @notice Returns true if a codeHash is filtered by a given address or its subscription.
     */
    function isCodeHashFiltered(address registrant, bytes32 codeHash) external view returns (bool) {
        Registration memory registration = _registrations[registrant];
        if (registration.subscription != address(0)) {
            return _filteredCodeHashes[registration.subscription].contains(codeHash);
        }
        return _filteredCodeHashes[registrant].contains(codeHash);
    }

    /**
     * @notice Returns true if the hash of an address's code is filtered by a given address or its subscription.
     */
    function isCodeHashOfFiltered(address registrant, address operatorWithCode) external view returns (bool) {
        bytes32 codeHash = operatorWithCode.codehash;
        Registration memory registration = _registrations[registrant];
        if (registration.subscription != address(0)) {
            return _filteredCodeHashes[registration.subscription].contains(codeHash);
        }
        return _filteredCodeHashes[registrant].contains(codeHash);
    }

    /**
     * @notice Returns true if an address has registered
     */
    function isRegistered(address addr) external view returns (bool) {
        return _registrations[addr].isRegistered;
    }

    /**
     * @notice Returns a list of filtered operators for a given address or its subscription.
     */
    function filteredOperators(address addr) external view returns (address[] memory) {
        Registration memory registration = _registrations[addr];
        if (registration.subscription != address(0)) {
            return _filteredOperators[registration.subscription].values();
        }
        return _filteredOperators[addr].values();
    }

    /**
     * @notice Returns a list of filtered codeHashes for a given address or its subscription.
     */
    function filteredCodeHashes(address addr) external view returns (bytes32[] memory) {
        Registration memory registration = _registrations[addr];
        if (registration.subscription != address(0)) {
            return _filteredCodeHashes[registration.subscription].values();
        }
        return _filteredCodeHashes[addr].values();
    }

    /**
     * @notice Returns the filtered operator at the given index of the list of filtered operators for a given address or
     *         its subscription.
     */
    function filteredOperatorAt(address registrant, uint256 index) external view returns (address) {
        Registration memory registration = _registrations[registrant];
        if (registration.subscription != address(0)) {
            return _filteredOperators[registration.subscription].at(index);
        }
        return _filteredOperators[registrant].at(index);
    }

    /**
     * @notice Returns the filtered codeHash at the given index of the list of filtered codeHashes for a given address or
     *         its subscription.
     */
    function filteredCodeHashAt(address registrant, uint256 index) external view returns (bytes32) {
        Registration memory registration = _registrations[registrant];
        if (registration.subscription != address(0)) {
            return _filteredCodeHashes[registration.subscription].at(index);
        }
        return _filteredCodeHashes[registrant].at(index);
    }

    /// Convenience function to compute the code hash of an arbitrary contract;
    /// the result can be passed to `setFilteredCodeHash`.
    function codeHashOf(address a) external view returns (bytes32) {
        return a.codehash;
    }
}