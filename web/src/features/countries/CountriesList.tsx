import { useState, type CSSProperties, type FormEvent } from 'react';
import { type Country } from './country.types';
import { useCountries } from './useCountries';
import { useCreateCountry } from './useCreateCountry';
import { useUpdateCountry } from './useUpdateCountry';
import { useDeleteCountry } from './useDeleteCountry';

export function CountriesList() {
  const [countryId, setCountryId] = useState('');
  const [name, setName] = useState('');
  const [editingCountry, setEditingCountry] = useState<Country | null>(null);

  const countriesQuery = useCountries();
  const createCountry = useCreateCountry();
  const updateCountry = useUpdateCountry();
  const deleteCountry = useDeleteCountry();

  const countries = countriesQuery.data?.data ?? [];

  const isSaving = createCountry.isPending || updateCountry.isPending;
  const isBusy = isSaving || deleteCountry.isPending;

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();

    try {
      if (editingCountry) {
        await updateCountry.mutateAsync({
          id: editingCountry.countryId,
          data: {
            countryId: countryId.trim(),
            name: name.trim(),
          },
        });
      } else {
        await createCountry.mutateAsync({
          countryId: countryId.trim(),
          name: name.trim(),
        });
      }

      setCountryId('');
      setName('');
      setEditingCountry(null);
      countriesQuery.refetch();
    } catch (error) {
      console.error(error);
    }
  };

  const handleStartEdit = (country: Country) => {
    setEditingCountry(country);
    setCountryId(country.countryId);
    setName(country.name);
  };

  const handleCancelEdit = () => {
    setEditingCountry(null);
    setCountryId('');
    setName('');
  };

  const handleDelete = async (country: Country) => {
    if (!window.confirm(`Delete country ${country.countryId}?`)) {
      return;
    }

    await deleteCountry.mutateAsync(country.countryId);
    countriesQuery.refetch();
  };

  return (
    <section style={styles.page}>
      <div>
        <h2 style={styles.heading}>Countries</h2>
        <p style={styles.description}>
          Add, edit, and manage your country list.
        </p>
      </div>

      <div style={styles.formCard}>
        <h3 style={styles.cardTitle}>Add a new country</h3>
        <p style={styles.cardDescription}>
          Enter a country code and name to get started.
        </p>

        <form onSubmit={handleSubmit}>
          <div style={styles.formRow}>
            <div style={styles.field}>
              <label style={styles.label}>Country code</label>
              <input
                value={countryId}
                placeholder='e.g. LK'
                onChange={(e) => setCountryId(e.target.value)}
                disabled={!!editingCountry}
                style={styles.input}
              />
            </div>

            <div style={{ ...styles.field, flex: 2 }}>
              <label style={styles.label}>Country name</label>
              <input
                value={name}
                placeholder='e.g. Sri Lanka'
                onChange={(e) => setName(e.target.value)}
                style={styles.input}
              />
            </div>

            <button type='submit' style={styles.primaryButton} disabled={isBusy}>
              {editingCountry ? 'Update Country' : 'Add Country'}
            </button>
          </div>

          {editingCountry && (
            <div style={{ marginTop: '12px' }}>
              <button type='button' style={styles.secondaryButton} onClick={handleCancelEdit}>
                Cancel
              </button>
            </div>
          )}
        </form>
      </div>

      <div style={styles.tableCard}>
        <div style={styles.tableHeader}>
          <h3 style={styles.cardTitle}>Country list</h3>
        </div>

        {countriesQuery.isLoading && <p style={styles.message}>Loading countries...</p>}

        {!countriesQuery.isLoading && countries.length === 0 && (
          <p style={styles.message}>No countries found.</p>
        )}

        {countries.length > 0 && (
          <table style={styles.table}>
            <thead>
              <tr>
                <th style={styles.th}>Code</th>
                <th style={styles.th}>Country name</th>
                <th style={styles.th}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {countries.map((country) => (
                <tr key={country.countryId}>
                  <td style={styles.td}>
                    <span style={styles.codeBadge}>{country.countryId}</span>
                  </td>
                  <td style={styles.td}>{country.name}</td>
                  <td style={styles.td}>
                    <div style={styles.actions}>
                      <button type='button' style={styles.editButton} onClick={() => handleStartEdit(country)}>
                        Edit
                      </button>
                      <button type='button' style={styles.deleteButton} onClick={() => handleDelete(country)}>
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}

const styles: Record<string, CSSProperties> = {
  page: {
    maxWidth: '900px',
    margin: '0 auto',
    padding: '16px',
  },
  heading: {
    fontSize: '42px',
    fontWeight: 700,
    color: '#24364f',
    marginBottom: '8px',
  },
  description: {
    color: '#6b7280',
    marginBottom: '28px',
  },
  formCard: {
    backgroundColor: '#f7fafc',
    border: '1px solid #e2e8f0',
    borderRadius: '12px',
    padding: '20px',
    marginBottom: '24px',
  },
  tableCard: {
    backgroundColor: '#ffffff',
    border: '1px solid #e2e8f0',
    borderRadius: '12px',
    overflow: 'hidden',
  },
  tableHeader: {
    padding: '20px',
    borderBottom: '1px solid #e5e7eb',
  },
  cardTitle: {
    margin: 0,
    color: '#24364f',
  },
  cardDescription: {
    color: '#6b7280',
    marginBottom: '20px',
  },
  formRow: {
    display: 'flex',
    gap: '12px',
    alignItems: 'end',
  },
  field: {
    display: 'flex',
    flexDirection: 'column',
    flex: 1,
    gap: '6px',
  },
  label: {
    fontWeight: 600,
  },
  input: {
    padding: '10px',
    border: '1px solid #cbd5e1',
    borderRadius: '6px',
  },
  primaryButton: {
    padding: '10px 18px',
    backgroundColor: '#8ab4f8',
    border: 'none',
    borderRadius: '6px',
    color: '#fff',
    cursor: 'pointer',
    height: '42px',
  },
  secondaryButton: {
    padding: '8px 16px',
  },
  table: {
    width: '100%',
    borderCollapse: 'collapse',
  },
  th: {
    textAlign: 'left',
    padding: '14px 20px',
    backgroundColor: '#f8fafc',
  },
  td: {
    padding: '14px 20px',
    borderTop: '1px solid #e5e7eb',
  },
  codeBadge: {
    backgroundColor: '#eef2f7',
    padding: '4px 8px',
    borderRadius: '4px',
    fontWeight: 600,
  },
  actions: {
    display: 'flex',
    gap: '8px',
  },
  editButton: {
    padding: '8px 14px',
    borderRadius: '6px',
  },
  deleteButton: {
    padding: '8px 14px',
    borderRadius: '6px',
    color: '#c24141',
  },
  message: {
    padding: '20px',
  },
};
